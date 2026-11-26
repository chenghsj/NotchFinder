ObjC.import('AppKit')

function waitUntil(check, timeout) {
    const deadline = Date.now() + timeout
    do {
        const result = check()
        if (result) return result
        // NSRunningApplication refreshes launch and exit state between main run loop turns.
        $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.1))
    } while (Date.now() < deadline)
    return null
}

function run([action, bundleID, bundlePath]) {
    const path = ObjC.unwrap($.NSURL.fileURLWithPath(bundlePath).URLByResolvingSymlinksInPath.path)

    function runningCopies() {
        const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleID)
        const matches = []
        for (let i = 0; i < apps.count; i++) {
            const app = apps.objectAtIndex(i)
            if (app.isTerminated) continue
            const bundleURL = app.bundleURL
            if (!bundleURL || bundleURL.isNil()) continue
            const appPath = ObjC.unwrap(bundleURL.URLByResolvingSymlinksInPath.path)
            if (appPath === path) matches.push(app)
        }
        return matches
    }

    if (action === 'pid') {
        const app = waitUntil(() => runningCopies().find(app => app.isFinishedLaunching), 10000)
        if (!app) throw new Error(`Test app did not finish launching at ${path}`)
        return app.processIdentifier
    }

    if (action !== 'quit') throw new Error(`Unknown action ${action}`)

    // An interrupted launch request can register its process after cleanup starts.
    const apps = waitUntil(() => {
        const copies = runningCopies()
        return copies.length > 0 ? copies : null
    }, 1000)
    if (!apps) return

    for (const app of apps) app.terminate
    // Keep tracking these apps even if Launch Services drops their bundle URL during exit.
    const allExited = () => apps.every(app => app.isTerminated)
    if (waitUntil(allExited, 3000)) return

    for (const app of apps) {
        if (!app.isTerminated) app.forceTerminate
    }
    if (!waitUntil(allExited, 3000)) throw new Error(`Test app is still running at ${path}`)
}
