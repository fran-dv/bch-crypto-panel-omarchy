import QtQuick
import Quickshell.Io
import "Model.js" as Model

// One CoinGecko GET via curl. The HTTP status is appended to stdout with
// `-w`, so callers get (status, body) with status 0 for transport failures.
// `tag` rides along so the handler knows what the response was for even
// if the caller's state moved on while it was in flight.
//
// `completed` fires only once stdout has closed AND the process has exited,
// so `running` is already false and a handler may immediately fetch again.
Process {
  id: req

  property var tag: null

  property string _output: ""
  property bool _streamDone: false
  property bool _exited: false

  signal completed(int status, string body, var tag)

  function fetch(url, tag) {
    if (req.running) return false
    req.tag = tag
    req._output = ""
    req._streamDone = false
    req._exited = false
    req.command = ["curl", "-sS", "--max-time", "8", "-w", "\n%{http_code}", url]
    req.running = true
    return true
  }

  function _maybeComplete() {
    if (!req._streamDone || !req._exited) return
    req._streamDone = false
    req._exited = false
    var res = Model.splitResponse(req._output)
    req.completed(res.status, res.body, req.tag)
  }

  // runningChanged instead of exited: same moment, but no enum-typed
  // parameters for tooling to resolve.
  onRunningChanged: {
    if (req.running) return
    req._exited = true
    req._maybeComplete()
  }

  stdout: StdioCollector {
    id: collector
    waitForEnd: true
    onStreamFinished: {
      req._output = collector.text
      req._streamDone = true
      req._maybeComplete()
    }
  }
}
