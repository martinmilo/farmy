require "open3"
require "yaml"

# How the shared dotfiles clone (farmy-shared/dotfiles) reaches app containers. It must never be
# writable inside one: ~/.gitconfig and the other dotfiles there are links into it.
#
#   dotfiles_switched_off · dotfiles_switched_on   farmy.yml without, and again with, its dotfiles: entry
#   dotfiles_mount_made_writable "shop"   shop's container now has farmy-shared with no read-only dotfiles
#                                         submount, as a container created by an older farmy has it
#   refute_dotfiles_applied_in "shop"      since then, nothing ran farmy-home.sh or the entrypoint in shop
#   assert_shared_dotfiles_untouched       the shared clone has no modified or new file
module DotfilesMounts
  # farmy.yml without its dotfiles: entry, and with it again (the same repository as before).
  def dotfiles_switched_off
    @saved_dotfiles = (YAML.safe_load(read_file("farmy.yml")) || {})["dotfiles"]
    configure_toolbox dotfiles: nil
    note_situation "farmy.yml configures no dotfiles."
  end

  def dotfiles_switched_on
    configure_toolbox dotfiles: @saved_dotfiles
    note_situation "farmy.yml configures the dotfiles repository again."
  end

  # submount: :gone (no dotfiles submount at all, as an older compose has it) or :writable (the submount is
  # there but read-write).
  def dotfiles_mount_made_writable(service, submount: :gone)
    change_docker_state do |state|
      c = state["containers"][service] or raise "no container #{service}; start it first"
      dotfiles = ->(m) { m["name"] == "farmy-shared" && (m["subpath"] == "dotfiles" || m["target"].to_s.end_with?("/dotfiles")) }
      submount == :writable ? c["volumes"].select(&dotfiles).each { |m| m.delete("ro") } : c["volumes"].reject!(&dotfiles)
      unless c["volumes"].any? { |m| m["name"] == "farmy-shared" && m["target"] == "/home/dev/.farmy-shared" }
        c["volumes"] << { "name" => "farmy-shared", "target" => "/home/dev/.farmy-shared" }
      end
      c["volumes"].each { |m| m.delete("ro") if m["name"] == "farmy-shared" }
    end
    @execs_before_writable = docker_state["execs"].size
    note_situation(submount == :writable ? "#{service}'s container has its farmy-shared dotfiles submount read-write." : "#{service}'s container mounts farmy-shared read-write at /home/dev/.farmy-shared with no read-only dotfiles submount, as a container created by an older farmy (or without dotfiles set) does.")
  end

  def refute_dotfiles_applied_in(service)
    runs = docker_state["execs"].drop(@execs_before_writable || 0).select do |e|
      e["container"] == service && e["command"].any? { |w| w.include?("farmy-home") || w.include?("farmy-entrypoint") }
    end
    assert_empty runs, "Expected no dotfiles to be applied in #{service}, whose shared dotfiles clone is writable there (its links, ~/.gitconfig " \
                       "among them, would let anything in the container write into the clone). It ran: #{runs.map { |e| e["command"].join(" ") }.join(" | ")}.#{transcript}"
  end

  def assert_shared_dotfiles_untouched
    root = File.join(docker_journal, "volumes", "farmy-shared", "dotfiles")
    out, = Open3.capture2e(Workspace::GIT_ENV, "git", "-C", root, "-c", "safe.directory=*", "status", "--porcelain")
    assert_empty out.strip, "Expected the shared dotfiles clone to be left as it was; it has changes:\n#{out}#{transcript}"
  end
end
