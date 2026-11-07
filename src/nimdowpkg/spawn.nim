import posix

## Starting external programs (key bindings, autostart).

proc reapChildren(sig: cint) {.noconv.} =
  var status: cint
  while waitpid(-1.Pid, status, WNOHANG) > 0:
    discard

proc installChildReaper*() =
  ## Reaps finished children. A handler (rather than SIG_IGN) is used because
  ## ignored signal dispositions are inherited by exec'd programs.
  var sa: Sigaction
  sa.sa_handler = reapChildren
  discard sigemptyset(sa.sa_mask)
  sa.sa_flags = SA_RESTART or SA_NOCLDSTOP
  discard sigaction(SIGCHLD, sa)

proc spawnShell*(command: string): bool =
  ## Runs `command` with `sh -c`, detached from the window manager.
  let pid = fork()
  if pid < 0:
    return false
  if pid == 0:
    discard setsid()
    var args = allocCStringArray(["sh", "-c", command])
    discard execvp("sh", args)
    posix.exitnow(127)
  return true
