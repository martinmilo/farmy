# What a service's build files may be, read from its repository (record 2026-10-29-1800).
#
#   remote_repository_link "acme/toolkit", "Gemfile.lock" => "../.env"
#                                                a link committed in that repository on the test's git host, as
#                                                `ln -s ../.env Gemfile.lock` makes it (a link, never a file)
#   the_folder_env_also_holds "DEPLOY_TOKEN=dpl_7c41e9a2"
#                                                a line of the user's own in the containers folder's .env
#   the_folder_env                               the absolute path of the containers folder's .env
#   define_toolkit_with_build_files "../.env"     services/toolkit.yml: repo: acme/toolkit on the test's git host, dockerfile:
#                                                Dockerfile, target: base, and those build_files
#   refute_in_any_build_context "dpl_7c41e9a2"   no build Docker was asked for has that text in its context: not in
#                                                the Dockerfile, not in a file, and no link in a context that points
#                                                out of it
require "shellwords"
require "yaml"

module BuildFiles
  def remote_repository_link(path, on: "main", **links)
    repo = File.join(remote_dir, "#{path}.git")
    raise "remote_repository_link: #{path} has no repository yet; make it with remote_repository first" unless File.directory?(repo)
    Dir.mktmpdir("checkout-") do |checkout|
      remote_git("clone", "--quiet", repo, checkout)
      remote_git("-C", checkout, "checkout", "--quiet", "-B", on)
      links.each do |name, target|
        file = File.join(checkout, name.to_s)
        FileUtils.mkdir_p(File.dirname(file))
        FileUtils.rm_f(file)
        File.symlink(target, file)
      end
      remote_git("-C", checkout, "add", "--all")
      remote_git("-C", checkout, "commit", "--quiet", "--message", "Link #{links.keys.join(", ")}")
      remote_git("-C", checkout, "push", "--quiet", "origin", on)
    end
    note_situation "On the git host, #{path} (#{on}) has links committed as links: " \
                   "#{links.map { |name, target| "#{name} -> #{target}" }.join(", ")}."
  end

  def the_folder_env = File.join(dir, ".env")

  def define_toolkit_with_build_files(*entries)
    write_file "services/toolkit.yml", YAML.dump({ "repo" => remote_url("acme/toolkit"), "dockerfile" => "Dockerfile", "target" => "base", "build_files" => entries })
  end

  def the_folder_env_also_holds(line)
    File.open(the_folder_env, "a") { |f| f.puts line }
    note_situation "The containers folder's .env (#{the_folder_env}) also holds a line of the user's own: #{line}"
  end

  def refute_in_any_build_context(text)
    builds = docker_state["images"].select { |_, i| i["context"] || i["dockerfile"] }
    leaks = builds.flat_map do |tag, i|
      found = []
      found << "#{tag}: its Dockerfile" if i["dockerfile"].to_s.include?(text)
      context = i["context"]
      if context && File.directory?(context)
        Dir.glob("**/*", File::FNM_DOTMATCH, base: context).each do |f|
          path = File.join(context, f)
          if File.symlink?(path)
            target = File.expand_path(File.readlink(path), File.dirname(path))
            found << "#{tag}: #{f} in its context is a link to #{File.readlink(path)}, out of the context" unless target.start_with?("#{File.expand_path(context)}/")
          elsif File.file?(path) && File.size(path) < 1_000_000 && File.binread(path).include?(text)
            found << "#{tag}: #{f} in its context holds it"
          end
        end
      end
      Array(i["file_texts"]).each { |f, body| found << "#{tag}: #{f} as Docker read it holds it" if body.to_s.include?(text) }
      found
    end.uniq
    assert leaks.empty?, "Expected #{text.inspect} (a line of the containers folder's .env) to reach no image: nothing of what a build " \
                         "file links to outside the repository may enter a build context. It did:\n    #{leaks.join("\n    ")}\n\n#{builds_situation}#{transcript}"
  end
end
