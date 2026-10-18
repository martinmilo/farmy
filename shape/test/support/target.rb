# Where the program under test is. bin/verify passes the work folder as SUT_ROOT;
# run from shape/ without it, the work folder next to shape/ is used.
module Target
  module_function

  def root
    ENV.fetch("SUT_ROOT") { File.expand_path("../../../work", __dir__) }
  end

  def path(relative)
    File.join(root, relative)
  end
end
