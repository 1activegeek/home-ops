The diff in this directory is applied to the stock hermes-agent image at boot by
the patch-memory initContainer (see ../helmrelease.yaml). It is rendered into the
hermes-memory-patch ConfigMap by the configMapGenerator in ../kustomization.yaml.

Do not hand-edit it during an image bump. Forward-port it:

    scripts/hermes-patch/regen.sh <old-tag> <new-tag>
    scripts/hermes-patch/verify.sh                      # must pass before merging

Full context, upgrade procedure and removal steps: docs/hermes-memory-patch.md
