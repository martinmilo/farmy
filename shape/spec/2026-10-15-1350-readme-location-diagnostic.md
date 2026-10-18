# Identify the public README in test diagnostics

The worker updated work/README.md while the existing ReadmeTest checks the repository-root
README.md, one directory above work/. Its failure previously said only README, which was
ambiguous from the worker's folder. Name the established location in both command-coverage
failure messages. The file selected by the test and its assertions remain unchanged.
