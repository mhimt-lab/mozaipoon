import Foundation
import WipeMosaicCore

// A text worker started by `analyzeText` runs and exits here.
runTextWorkerIfRequested()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

// Line-buffer stdout so progress reaches a pipe (the UI server) immediately.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    switch try Command.parse(Array(CommandLine.arguments.dropFirst())) {
    case .help: print(usage)
    case .run(let o): try await runMosaic(o)
    case .preview(let o): try await runPreview(o)
    case .info(let url): try await printInfo(url)
    case .frame(let input, let at, let output): try await writeFrame(input: input, at: at, output: output)
    case .facesDist(let urls): try printFaceDistances(urls)
    case .people(let input, let outDir, let render, let photos, let match):
        try await listPeople(input: input, outDir: outDir, render: render, photos: photos, match: match)
    case .text(let input, let options, let list): try await listText(input: input, options: options, list: list)
    case .selfCheck:
        let failures = selfCheck()
        for f in failures { print("FAIL \(f)") }
        guard failures.isEmpty else { fail("\(failures.count) check(s) failed") }
        print("selfcheck: all passed")
    }
} catch let e as ToolError {
    fail(e.description)
} catch {
    fail("\(error)")
}
