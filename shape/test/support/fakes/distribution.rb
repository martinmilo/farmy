# Registry and artifact behavior at Docker's public boundary; no farmy policy is inferred.
def cmd_pull(argv)
  _, names = parse(argv, valued: %w[platform])
  ref = names.first.to_s
  ($state["pulls"] ||= []) << ref
  fail_with("pull failed for #{ref}: registry unavailable") if Array($state["pull_failures"]).include?(ref)
  remote = ($state["registry"] || {})[ref]
  fail_with("manifest unknown: #{ref}") unless remote
  images[ref] = JSON.parse(JSON.generate(remote))
  puts "Pulled #{ref}"
end

def copy_image_artifact(from, to)
  name, path = from.to_s.split(":", 2)
  c = find_container(name) if path&.start_with?("/")
  return unless c
  artifacts = (find_image(c["image"]) || {})["artifacts"]
  fail_with("Could not find file #{path} in container #{name}") if artifacts && !artifacts.key?(path)
  content = artifacts && artifacts[path]
  return unless content
  destination = File.directory?(to) ? File.join(to, File.basename(path)) : to
  File.binwrite(destination, content)
  File.chmod(0755, destination)
end

def record_buildx(argv)
  opts, = parse(argv, valued: BUILD_VALUED)
  ($state["buildx"] ||= []) << { "tags" => values(opts, "t", "tag"), "platforms" => values(opts, "platform").flat_map { |p| p.split(",") },
    "push" => flag?(opts, "push"), "outputs" => values(opts, "output", "o"), "labels" => values(opts, "label").to_h { |p| p.split("=", 2) } }
  fail_with("buildx failed: builder unavailable") if $state["buildx_failure"]
end
