# The holder's socket (FARMY_HOLD_SOCKET, a folder of the test's own) as farmy creates it.
#
#   farmy_under_umask 0o000, "start", "shop", stdin: "…"   farmy (and the holder it starts) with that umask
#   assert_holder_socket_mode 0o600                        the socket exists with exactly that mode
module HolderSocket
  def farmy_under_umask(mask, *args, stdin: "")
    previous = File.umask(mask)
    note_situation "farmy runs with umask #{format("%03o", mask)}, so anything it creates without setting a mode is open to everyone."
    farmy(*args, stdin: stdin)
  ensure
    File.umask(previous) if previous
  end

  def assert_holder_socket_mode(mode)
    path = File.join(scratch, "hold", "hold.sock")
    assert File.socket?(path), "Expected the holder's socket at #{path}; there is #{File.exist?(path) ? "something else" : "nothing"}.#{transcript}"
    got = File.stat(path).mode & 0o777
    assert_equal mode, got, "Expected the holder's socket #{path} to be #{format("%04o", mode)} (only its owner may ask it for values), " \
                            "whatever the umask; it is #{format("%04o", got)}.#{transcript}"
  end
end
