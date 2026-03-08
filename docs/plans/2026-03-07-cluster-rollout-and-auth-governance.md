# Cluster Rollout And Auth Governance Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Reconcile rollout tracking with the live cluster, standardize authentication policy for routed apps, remove Uptime Kuma, and define the next steps for the remaining phases.

**Architecture:** Keep rollout tracking in the existing public/private deployment plan pair, move auth policy into a dedicated public architecture document, and treat external route exposure as an explicit governance decision. Remove deprecated monitoring components from Git so Flux can prune them cleanly.

**Tech Stack:** Flux CD, Kubernetes, Envoy Gateway, Authentik, Talos, Taskfile validation workflow, Markdown documentation

---

### Task 1: Publish auth policy

**Files:**
- Create: `docs/architecture/authentication.md`
- Modify: `AGENTS.md`
- Test: `task validate:preflight`

**Step 1: Write the documentation changes**

- Add a public auth architecture doc describing exposure classes, allowed auth modes, and decision rules for `envoy-external` and `envoy-internal`.
- Add an `AGENTS.md` note directing future agents to read the auth architecture doc before adding or changing routed apps.

**Step 2: Review for secrecy boundaries**

- Confirm the public auth doc does not include private IPs, storage mount paths, redirect URIs, secret names, or private addresses.

**Step 3: Run validation**

Run: `task validate:preflight`
Expected: validation completes successfully for the repo state after the doc change.

**Step 4: Commit**

```bash
git add AGENTS.md docs/architecture/authentication.md
git commit -m "docs: define auth policy for routed apps"
```

### Task 2: Reconcile rollout trackers

**Files:**
- Modify: `docs/deployment-plan.md`
- Modify: `.private/deployment-plan.md`
- Test: `kubectl --kubeconfig ./kubeconfig get kustomizations.kustomize.toolkit.fluxcd.io -A`

**Step 1: Update deployment status**

- Mark live apps as `deployed`, not `verified`, based on cluster state.
- Remove Uptime Kuma from the active roadmap.
- Update current focus, blockers, and session log to match current work.

**Step 2: Align planning rules**

- Add references to the auth architecture doc.
- Add planning guardrails for validation and post-phase doc updates.

**Step 3: Verify against cluster state**

Run: `kubectl --kubeconfig "./kubeconfig" get helmreleases.helm.toolkit.fluxcd.io -A`
Expected: deployed entries in the tracker match live HelmRelease state.

**Step 4: Commit**

```bash
git add docs/deployment-plan.md .private/deployment-plan.md
git commit -m "docs: reconcile deployment tracker with cluster state"
```

### Task 3: Remove Uptime Kuma from GitOps

**Files:**
- Modify: `kubernetes/apps/monitoring/kustomization.yaml`
- Delete: `kubernetes/apps/monitoring/uptime-kuma/ks.yaml`
- Delete: `kubernetes/apps/monitoring/uptime-kuma/app/kustomization.yaml`
- Delete: `kubernetes/apps/monitoring/uptime-kuma/app/helmrelease.yaml`
- Delete: `kubernetes/apps/monitoring/uptime-kuma/app/ocirepository.yaml`
- Test: `task validate:preflight`

**Step 1: Remove namespace registration**

- Delete the `./uptime-kuma/ks.yaml` entry from `kubernetes/apps/monitoring/kustomization.yaml`.

**Step 2: Remove manifests**

- Delete the Uptime Kuma Flux and Helm files so Flux can prune the deployment.

**Step 3: Run validation**

Run: `task validate:preflight`
Expected: validation passes without route or flux rendering regressions.

**Step 4: Commit**

```bash
git add kubernetes/apps/monitoring/kustomization.yaml kubernetes/apps/monitoring/uptime-kuma
git commit -m "refactor: remove uptime-kuma from monitoring stack"
```

### Task 4: Continue remaining rollout with governance checks

**Files:**
- Modify: `docs/deployment-plan.md`
- Modify: `.private/deployment-plan.md`
- Test: `task validate`

**Step 1: Use this checklist for every future phase**

- Choose exposure class.
- Choose auth mode.
- Verify public doc secrecy.
- Add manifests.
- Run `task validate:preflight` and `task validate`.
- Update deployment status.
- Update session log.

**Step 2: Prioritize remaining work**

- Phase 4: *Arr stack
- Phase 5: media support apps
- Phase 6: Shlink stack
- Phase 7: Teslamate
- Phase 8: AI stack
- Phase 9: books

**Step 3: Reserve `verified` for end-to-end checks**

- Only promote `deployed` items to `verified` after testing route behavior, auth behavior when applicable, and app-specific function.

**Step 4: Commit**

```bash
git add docs/deployment-plan.md .private/deployment-plan.md
git commit -m "docs: codify rollout governance workflow"
```
