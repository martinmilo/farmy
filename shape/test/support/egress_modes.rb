module EgressModes
  def egress_mode(value, at:)
    case at
    when "workspace egress.restrict"
      egress_apps global: value
    when "service restrict"
      egress_apps global: false, shop: value
    when "service egress.restrict"
      egress_apps global: false
      nested_restriction value
    else
      raise ArgumentError, "Unknown egress setting #{at}"
    end
  end

  def assert_egress_coverage_documented
    guides = Dir.glob(File.join(Target.root, "docs", "**", "*.md"))
    text = [root_file("README.md"), *guides.map { |file| File.read(file) }].join("\n")
    { "canonical off, audit and enforce modes" => /\boff\b.{0,200}\baudit\b.{0,200}\benforce\b/im,
      "HTTP and CONNECT coverage" => /\bHTTP\b.{0,120}\bCONNECT\b/im,
      "opaque CONNECT tunnels without traffic inspection" => /(?:CONNECT.{0,180}(?:opaque|not inspect|without inspect)|opaque.{0,120}CONNECT)/im,
      "no independent outward route for other protocols in audit or enforce" => /(?:other protocols.{0,180}(?:no|without).{0,100}(?:route|outbound)|(?:no|without).{0,100}(?:route|outbound).{0,180}other protocols)/im,
      "image builds are outside the runtime gate" => /(?:image builds?.{0,160}(?:outside|not covered|not filtered)|(?:outside|does not cover|does not filter).{0,160}image builds?)/im }.each do |claim, pattern|
      assert pattern.match?(text), "Expected the shipped README or guides to document #{claim}."
    end
  end
end
