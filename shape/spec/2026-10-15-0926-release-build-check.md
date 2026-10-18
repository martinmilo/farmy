# Checking the real release build without publishing

The distribution scenario requiring one image built for both architectures means a
farmy image, not an unrelated scratch image. The release entry point therefore also
supports `bin/release VERSION --image ROLE --output ARCHIVE`, with ROLE one of
control, keys, knowledge or gate. This uses the same version validation, build inputs,
labels and two architectures as publication, but exports the selected image as an
OCI archive without pushing or requiring a registry. The integration case uses gate.

This is a public build-check handle for the requested integration scenario. It keeps
the acceptance suite outside the worker's source and avoids publishing test artifacts.
The fake records output arguments as well as platforms and tags. With a real capable
builder, the test inspects the exported archive for both platform descriptors.

## Scenarios

- Exporting the gate image selects both architectures and an OCI destination without a push.
- An unknown image role is refused before starting a release build.
- A capable real buildx exports the farmy gate image with both platform descriptors.
