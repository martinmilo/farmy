require "fileutils"

# farmy's own entrypoint is always the one installed in an app image, over any custom toolbox; a custom
# toolbox adds startup logic through toolbox/start.sh, which that entrypoint runs.
#
#   custom_toolbox entrypoint: :before_modes    toolbox/ in the containers folder whose Dockerfile installs its own
#                                               entrypoint.sh (an older farmy's, which knows no modes)
#   custom_toolbox entrypoint: :claims_modes    … one that claims modes it does not have ("git-config, bogus")
#   custom_toolbox start_sh: "…"                … no entrypoint of its own, a start.sh hook
#   entrypoint_modes_label "shop"               the image's farmy.entrypoint.modes label, split into modes
#   run_app_startup "shop"                      the installed entrypoint's normal start, as Docker runs it
module FarmyEntrypoint
  def custom_toolbox(entrypoint: nil, start_sh: nil)
    dockerfile = +"ARG BASE\nFROM ${BASE}\nRUN mkdir -p /opt/team-environment\n"
    case entrypoint
    when :before_modes
      write_file "toolbox/entrypoint.sh", fixture("farmy/old-entrypoint.sh")
      dockerfile << "COPY entrypoint.sh /usr/local/bin/farmy-entrypoint\nENTRYPOINT [\"/usr/local/bin/farmy-entrypoint\"]\n"
    when :claims_modes
      write_file "toolbox/entrypoint.sh", "#!/bin/sh\n# farmy-entrypoint-modes: git-config, bogus\nexec tail -f /dev/null\n"
      dockerfile << "COPY entrypoint.sh /usr/local/bin/farmy-entrypoint\nENTRYPOINT [\"/usr/local/bin/farmy-entrypoint\"]\n"
    end
    write_file "toolbox/start.sh", start_sh if start_sh
    write_file "toolbox/Dockerfile", dockerfile
    note_situation "The containers folder has a custom toolbox/ (#{[("its own entrypoint.sh: #{entrypoint}" if entrypoint), ("a start.sh hook" if start_sh)].compact.join(", ").then { |s| s.empty? ? "a Dockerfile only" : s }})."
  end

  def entrypoint_modes_label(service)
    image = docker_state["images"]["farmy/#{service}:dev"]
    assert image, "Expected the app image farmy/#{service}:dev to be built.#{transcript}"
    image.fetch("labels", {})["farmy.entrypoint.modes"].to_s.split(/[\s,]+/).reject(&:empty?)
  end

  def run_app_startup(service)
    change_docker_state { |state| state["entrypoint_runtime"] = true }
    entrypoint = toolbox_build(service)["entrypoint"]
    refute_empty Array(entrypoint), "Expected the app image to name its entrypoint.#{transcript}"
    execute(File.join(Farmy::FAKES, "docker"), ["exec", "-u", "root", service, *entrypoint], shown_as: "docker", env: farmy_env.compact)
  end

  def app_home_file_content(service, path)
    file = File.join(docker_journal, "homes", service, path)
    File.exist?(file) ? File.read(file) : nil
  end
end
