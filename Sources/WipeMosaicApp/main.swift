import WipeMosaicCore

// A text worker started by `analyzeText` (the app runs itself to read text in several
// processes) runs and exits here, before any window is created.
runTextWorkerIfRequested()
WipeMosaicApp.main()
