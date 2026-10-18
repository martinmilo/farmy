# Observe submitted build inputs. This is deliberately not a Dockerfile interpreter:
# only the documented tools-install.sh may be executed, by the existing DESTDIR helper.
require "shellwords"

module ToolboxAndDotfiles
  def assert_managed_toolbox_consumes_installer(service)
    observed = toolbox_build_observation(toolbox_build(service))
    assert_includes observed.fetch(:scripts), "tools-install.sh",
      "Expected #{service}'s managed Dockerfile RUN to invoke the captured tools-install.sh, directly or through a copied shell wrapper. Copying or mentioning it alone does not install tools.#{transcript}"
  end

  def exercise_captured_toolbox_installer(service)
    @tool_build_observation = toolbox_build_observation(toolbox_build(service))
    @tool_install_root = File.join(scratch, "installed-toolbox")
    FileUtils.mkdir_p(@tool_install_root)
    if @tool_build_observation.fetch(:scripts).include?("tools-install.sh")
      install_captured_toolbox service
    else
      @finished = Commands::Finished.new("observe #{service}'s custom Dockerfile (no managed installer invoked)", "", "", 0, [])
    end
  end

  def assert_unmanaged_toolbox(service, packages:)
    observed = @tool_build_observation || toolbox_build_observation(toolbox_build(service))
    refute_installed_counter
    assert_empty @tool_release_requests,
      "An opted-out custom toolbox must not download its selected counter artifact.#{transcript}"
    commands = observed.fetch(:commands)
    package_commands = commands.select do |words|
      %w[apt apt-get apk].include?(File.basename(words.first.to_s)) && (words.include?("install") || words.include?("add"))
    end
    packages.each do |name|
      refute package_commands.any? { |words| words.include?(name) },
        "toolbox.managed:false must not install selected distro package #{name}; observed commands: #{package_commands.inspect}.#{transcript}"
    end
    package_file = (toolbox_build(service)["file_texts"] || {})["packages.txt"].to_s.lines.map(&:strip)
    consuming_packages = commands.any? { |words| words.any? { |word| word.include?("packages.txt") } }
    refute consuming_packages && (package_file & packages).any?,
      "toolbox.managed:false must not consume packages.txt containing its selected packages.#{transcript}"
    selected_urls = YAML.safe_load(read_file("farmy.yml")).dig("tool_catalogue", "counter", "artifacts").values.map { |artifact| artifact.fetch("url") }
    downloads = commands.select { |words| %w[curl wget].include?(File.basename(words.first.to_s)) }
    refute downloads.any? { |words| words.any? { |word| selected_urls.include?(word) } },
      "toolbox.managed:false must not download selected artifacts directly in a RUN command.#{transcript}"
  end

  private

  def toolbox_build_observation(build)
    files = build["file_texts"] || {}
    copied = {}
    observed = { scripts: [], commands: [] }
    workdir = "/"
    instructions = build.fetch("dockerfile").gsub(/\\\r?\n\s*/, " ").lines
    instructions.each do |line|
      match = line.match(/\A\s*(COPY|RUN|WORKDIR)\s+(.+?)\s*\z/i)
      next unless match
      directive, body = match.captures
      case directive.upcase
      when "WORKDIR"
        workdir = File.expand_path(body, workdir)
      when "COPY"
        next if body.match?(/\A--from(?:=|\s)/)
        words = toolbox_instruction_words(body.sub(/\A(?:--\S+\s+)+/, ""))
        destination = words.pop
        next unless destination
        words.each do |source|
          source = source.delete_prefix("./").delete_suffix("/")
          files.each_key do |path|
            next unless path == source || source == "." || path.start_with?(source + "/")
            suffix = path == source ? File.basename(path) : source == "." ? path : path.delete_prefix(source + "/")
            target = path != source || destination.end_with?("/") || words.length > 1 ? File.join(destination, suffix) : destination
            copied[File.expand_path(target, workdir)] = path
          end
        end
      when "RUN"
        commands = body.start_with?("[") ? [toolbox_instruction_words(body)] : toolbox_shell_commands(body)
        toolbox_observe_commands(commands, files, copied, workdir, observed)
      end
    end
    observed
  end

  def toolbox_observe_commands(commands, files, copied, workdir, observed)
    commands.each do |words|
      words = words.dup
      words.shift while words.first&.match?(/\A(?:[A-Za-z_]\w*=|then\z|do\z|if\z|!\z|exec\z)/)
      if %w[env command].include?(words.first)
        words.shift
        words.shift while words.first&.match?(/\A(?:-|[A-Za-z_]\w*=)/)
      end
      next if words.empty?
      observed[:commands] << words
      command = File.basename(words.first)
      if %w[sh bash dash ash zsh].include?(command)
        options = words.drop(1).take_while { |word| word.start_with?("-") }
        arguments = words.drop(1 + options.length)
        if options.any? { |option| option.match?(/\A-[^-]*c/) }
          toolbox_observe_commands(toolbox_shell_commands(arguments.first.to_s), files, copied, workdir, observed)
          next
        end
        script = arguments.first
      else
        script = words.first
      end
      path = script && File.expand_path(script, workdir)
      source = path && copied[path]
      # COPY file /existing-directory need not spell a trailing slash. Observe
      # that form without pretending to model the base image's filesystem.
      directory_source = path && copied[File.dirname(path)]
      source ||= directory_source if directory_source && File.basename(directory_source) == File.basename(path)
      next unless source && !observed[:scripts].include?(source)
      observed[:scripts] << source
      next if source == "tools-install.sh" # exercised with DESTDIR, never statically interpreted
      toolbox_observe_commands(toolbox_shell_commands(files.fetch(source)), files, copied, workdir, observed)
    end
  end

  def toolbox_instruction_words(body)
    body.start_with?("[") ? JSON.parse(body) : Shellwords.split(body)
  end

  # Split only unquoted command separators, preserving -c arguments for a second pass.
  # This observes command text; it does not evaluate conditionals, substitutions or RUNs.
  def toolbox_shell_commands(body)
    chunks, current, quote, escaped = [], +"", nil, false
    text = body.lines.reject { |line| line.lstrip.start_with?("#") }.join.gsub(/\\\r?\n\s*/, " ")
    text.each_char do |character|
      if escaped
        current << character
        escaped = false
      elsif character == "\\" && quote != "'"
        current << character
        escaped = true
      elsif quote
        current << character
        quote = nil if character == quote
      elsif character == "'" || character == '"'
        current << character
        quote = character
      elsif ";&|\n".include?(character)
        chunks << current
        current = +""
      else
        current << character
      end
    end
    chunks << current
    chunks.filter_map do |chunk|
      next if chunk.strip.empty? || chunk.lstrip.start_with?("#")
      Shellwords.split(chunk)
    end
  end
end
