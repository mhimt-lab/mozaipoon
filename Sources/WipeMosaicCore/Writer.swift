import AVFoundation
import CoreImage
import VideoToolbox

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ e: Error) { lock.withLock { if error == nil { error = e } } }
    var value: Error? { lock.withLock { error } }
}

/// What the output was encoded as (for the summary).
public struct OutputFormat: Sendable, CustomStringConvertible {
    public let codec: String
    public let bitrate: Int?  // bits per second; nil for ProRes
    public let tenBit: Bool
    public var description: String {
        let rate = bitrate.map { String(format: " %.1fMbps", Double($0) / 1_000_000) } ?? ""
        return "\(codec)\(tenBit ? " 10bit" : "")\(rate)"
    }
}

/// Luma bit depth of the source video. Many files (e.g. Sony XAVC, ffmpeg output) carry no
/// BitsPerComponent extension, so the codec configuration record is read as well; otherwise
/// 10-bit H.264 (High 10 / High 4:2:2 Intra) was re-encoded as 8-bit (2026-11-12).
func sourceBitDepth(_ fmt: CMFormatDescription) -> Int {
    let ext = (CMFormatDescriptionGetExtensions(fmt) as? [String: Any]) ?? [:]
    if let b = ext["BitsPerComponent"] as? Int { return b }
    let atoms = ext["SampleDescriptionExtensionAtoms"] as? [String: Any] ?? [:]
    if let hvcC = atoms["hvcC"] as? Data, hvcC.count > 17 {
        return Int(hvcC[hvcC.startIndex + 17] & 0x07) + 8  // bitDepthLumaMinus8
    }
    if let avcC = atoms["avcC"] as? Data, avcC.count > 6 {
        let b = [UInt8](avcC)
        guard [110, 122, 244].contains(b[1]) else { return 8 }  // only these profiles allow > 8 bit
        // Skip SPS and PPS; the High-profile extension then holds bit_depth_luma_minus8.
        var i = 6
        for _ in 0..<Int(b[5] & 0x1F) {
            guard i + 2 <= b.count else { return 10 }
            i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))
        }
        guard i < b.count else { return 10 }
        let pps = Int(b[i])
        i += 1
        for _ in 0..<pps {
            guard i + 2 <= b.count else { return 10 }
            i += 2 + (Int(b[i]) << 8 | Int(b[i + 1]))
        }
        return i + 1 < b.count ? Int(b[i + 1] & 0x07) + 8 : 10
    }
    return 8
}

private func codecFor(_ subtype: FourCharCode) -> (AVVideoCodecType, String)? {
    switch subtype {
    case kCMVideoCodecType_H264: return (.h264, "H.264")
    case kCMVideoCodecType_HEVC: return (.hevc, "HEVC")
    case kCMVideoCodecType_AppleProRes422: return (.proRes422, "ProRes 422")
    case kCMVideoCodecType_AppleProRes422HQ: return (.proRes422HQ, "ProRes 422 HQ")
    case kCMVideoCodecType_AppleProRes422LT: return (.proRes422LT, "ProRes 422 LT")
    case kCMVideoCodecType_AppleProRes422Proxy: return (.proRes422Proxy, "ProRes 422 Proxy")
    case kCMVideoCodecType_AppleProRes4444: return (.proRes4444, "ProRes 4444")
    default: return nil
    }
}

/// Pass 2: re-encode with the mosaic, matching the source codec, bit depth, color
/// properties and (for H.264/HEVC) bitrate. Frames without mosaic are passed to the
/// encoder as decoded, untouched. Audio tracks are copied without re-encoding.
public func writeMosaic(
    asset: AVURLAsset, info: VideoInfo, frames: [FrameFaces], render: RenderSettings,
    to output: URL, fileType: AVFileType, progress: @escaping @Sendable (Double) -> Void
) async throws -> OutputFormat {
    guard let fmt = try await info.track.load(.formatDescriptions).first else {
        throw ToolError("video track has no format description")
    }
    let ext = (CMFormatDescriptionGetExtensions(fmt) as? [String: Any]) ?? [:]
    let tenBit = sourceBitDepth(fmt) > 8
    // estimatedDataRate is wrong for some containers (MPEG-PS reported ~60x the real rate,
    // 2026-11-12), so cap it by the whole file's average rate (video + audio: an upper bound).
    var sourceRate = Double(try await info.track.load(.estimatedDataRate))
    if let bytes = try? asset.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, info.duration > 0 {
        let fileRate = Double(bytes) * 8 / info.duration
        if sourceRate <= 0 || sourceRate > fileRate { sourceRate = fileRate }
    }

    var (codec, codecName) = codecFor(CMFormatDescriptionGetMediaSubType(fmt)) ?? (.hevc, "HEVC")
    let isProRes = codecName.hasPrefix("ProRes")
    if tenBit && codec == .h264 { (codec, codecName) = (.hevc, "HEVC") }  // H.264 encoder is 8-bit only
    let pixelFormat: OSType =
        isProRes
        ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        : (tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

    let w = Int(info.naturalSize.width), h = Int(info.naturalSize.height)
    var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h]
    var bitrate: Int?
    if !isProRes {
        // Re-encoding loses a little; give the encoder 30% more than the source had.
        let target = max(Int(sourceRate * 1.3), 2_000_000)
        bitrate = target
        var props: [String: Any] = [AVVideoAverageBitRateKey: target]
        if info.fps > 0 { props[AVVideoExpectedSourceFrameRateKey] = Int(info.fps.rounded()) }
        if codec == .hevc && tenBit { props[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String }
        if codec == .h264 { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        settings[AVVideoCompressionPropertiesKey] = props
    }
    if let p = ext[kCVImageBufferColorPrimariesKey as String] as? String,
        let t = ext[kCVImageBufferTransferFunctionKey as String] as? String,
        let m = ext[kCVImageBufferYCbCrMatrixKey as String] as? String
    {
        settings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: p, AVVideoTransferFunctionKey: t, AVVideoYCbCrMatrixKey: m,
        ]
    }

    let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
    writer.shouldOptimizeForNetworkUse = fileType == .mp4
    let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    vIn.transform = info.transform
    vIn.expectsMediaDataInRealTime = false
    guard writer.canAdd(vIn) else { throw ToolError("cannot encode \(codecName) into .\(output.pathExtension)") }
    writer.add(vIn)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: vIn,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])

    let reader = try AVAssetReader(asset: asset)
    let vOut = AVAssetReaderTrackOutput(
        track: info.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
    vOut.alwaysCopiesSampleData = false
    guard reader.canAdd(vOut) else { throw ToolError("cannot decode video track") }
    reader.add(vOut)

    var audio: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
    for track in try await asset.loadTracks(withMediaType: .audio) {
        let hint = try await track.load(.formatDescriptions).first
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        input.expectsMediaDataInRealTime = false
        guard reader.canAdd(out), writer.canAdd(input) else {
            throw ToolError("this audio format cannot be copied into .\(output.pathExtension); save as .mov")
        }
        reader.add(out)
        writer.add(input)
        audio.append((out, input))
    }

    guard reader.startReading() else { throw reader.error ?? ToolError("cannot start reading") }
    guard writer.startWriting() else { throw writer.error ?? ToolError("cannot start writing") }
    writer.startSession(atSourceTime: .zero)

    let index = FaceIndex(frames: frames)
    let pad = render.pad, hold = render.hold
    let block = render.blockSize(for: info.size)
    let duration = max(info.duration, 0.001)
    let ctx = CIContext(options: [.cacheIntermediates: false])
    let cancelled = Flag()
    let failure = ErrorBox()
    let natural = CGRect(origin: .zero, size: info.naturalSize)

    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            group.enter()
            let vDone = Flag()
            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "wipe-mosaic.video")) {
                guard !vDone.isSet else { return }
                func finish() {
                    vIn.markAsFinished()
                    vDone.set()
                    group.leave()
                }
                while vIn.isReadyForMoreMediaData {
                    if cancelled.isSet || failure.value != nil { return finish() }
                    guard let sample = vOut.copyNextSampleBuffer() else { return finish() }
                    guard let src = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                    let ok: Bool = autoreleasepool {
                        let rects = index.allRects(at: pts.seconds, hold: hold, pad: pad)
                        if rects.isEmpty { return adaptor.append(src, withPresentationTime: pts) }
                        guard let pool = adaptor.pixelBufferPool else { return false }
                        var dst: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &dst) == kCVReturnSuccess, let dst else {
                            return false
                        }
                        CVBufferPropagateAttachments(src, dst)
                        let up = uprightImage(src, info)
                        let mosaicked = applyMosaic(up, rects: rects, block: block)
                        let raw = info.orientation == .up ? mosaicked : mosaicked.oriented(inverse(info.orientation))
                        let space =
                            CVImageBufferGetColorSpace(src)?.takeUnretainedValue()
                            ?? CGColorSpace(name: CGColorSpace.itur_709)
                        ctx.render(raw, to: dst, bounds: natural, colorSpace: space)
                        return adaptor.append(dst, withPresentationTime: pts)
                    }
                    if !ok {
                        failure.record(writer.error ?? ToolError("failed to append video frame at \(pts.seconds)s"))
                        return finish()
                    }
                    progress(min(0.99, pts.seconds / duration))
                }
            }

            for (i, (out, input)) in audio.enumerated() {
                group.enter()
                let done = Flag()
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "wipe-mosaic.audio.\(i)")) {
                    guard !done.isSet else { return }
                    func finish() {
                        input.markAsFinished()
                        done.set()
                        group.leave()
                    }
                    while input.isReadyForMoreMediaData {
                        if cancelled.isSet || failure.value != nil { return finish() }
                        guard let sample = out.copyNextSampleBuffer() else { return finish() }
                        if !input.append(sample) {
                            failure.record(writer.error ?? ToolError("failed to append audio"))
                            return finish()
                        }
                    }
                }
            }

            group.notify(queue: .global()) {
                if cancelled.isSet || failure.value != nil {
                    writer.cancelWriting()
                    reader.cancelReading()
                    cont.resume(throwing: cancelled.isSet ? CancellationError() : failure.value!)
                    return
                }
                if reader.status == .failed {
                    writer.cancelWriting()
                    cont.resume(throwing: reader.error ?? ToolError("reading failed"))
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume()
                    } else {
                        cont.resume(throwing: writer.error ?? ToolError("writing failed (status \(writer.status.rawValue))"))
                    }
                }
            }
        }
    } onCancel: {
        cancelled.set()
    }
    progress(1)
    return OutputFormat(codec: codecName, bitrate: bitrate, tenBit: tenBit)
}
