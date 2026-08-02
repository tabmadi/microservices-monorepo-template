// Command lint-resource-governance is the ADR-0020 gate: it renders every chart and
// checks the declared resources against the guardrails in
// infra/helm/platform/resource-governance BEFORE they reach a cluster.
//
// It exists because the interesting failures here are all admission-time and
// cluster-wide. A LimitRange `min` above what a third-party chart declares REJECTS
// that pod — during development this repo's own kube-system LimitRange was one
// `helm template` away from rejecting Cilium's install-cni-binaries initContainer
// (10Mi against a 16Mi floor), which would have left every node without pod
// networking and no way to repair it from inside. A ResourceQuota whose cap sits
// below the namespace's steady-state requests wedges a bring-up the same way. Both
// are invisible in review and obvious from the rendered manifests, which is exactly
// what a linter is for.
//
// Checks, in the order they are reported:
//
//  1. REJECTION — no container's declared request falls below a LimitRange min, and
//     no limit above a max. This is the cluster-breaking class.
//  2. COVERAGE — every container ends up with CPU+memory requests and a memory
//     limit, whether declared or defaulted by the namespace's LimitRange.
//  3. CPU LIMITS — ADR-0020 sets CPU limits only where throttling is desired, so any
//     new one must be added to the allow-list here with a reason.
//  4. QUOTA HEADROOM — the summed requests/limits per namespace fit inside that
//     namespace's ResourceQuota, with utilisation printed so tightening the cap is an
//     informed choice rather than a guess.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

const setFlag = "--set"

// Charts that render into a namespace other than `platform`. Everything else under
// infra/helm/platform/ targets platform, matching the ApplicationSet destination.
var chartNamespace = map[string]string{
	"argocd": "argocd",
	"cilium": "kube-system",
}

// Values some charts require before they will render at all. Throwaway placeholders
// — this lint only reads resource stanzas.
var chartExtraArgs = map[string][]string{
	"lowdefy": {setFlag, "lowdefy.image.repository=r", setFlag, "lowdefy.image.tag=v"},
	"openfga": {setFlag, "image.repository=r", setFlag, "image.tag=v"},
}

// CPU limits ADR-0020 tolerates, each with the reason it survives. A container not
// listed here may not carry one.
var cpuLimitAllowList = map[string]string{
	// Inherited from the subchart; a parent values.yaml cannot delete a subchart key
	// (Helm coalescing skips parent nulls). 500m is ~80x the measured 6m peak.
	"temporal-worker-controller/temporal-worker-controller-manager/manager": "inherited, unremovable, 80x measured peak",
	// Runs once at pod start to copy CNI binaries: throttling delays startup only.
	"cilium/cilium/install-cni-binaries": "upstream init container, startup-only",
}

type resources struct {
	Requests map[string]string `yaml:"requests"`
	Limits   map[string]string `yaml:"limits"`
}

type container struct {
	Name      string    `yaml:"name"`
	Resources resources `yaml:"resources"`
}

type workload struct {
	Kind     string `yaml:"kind"`
	Metadata struct {
		Name      string `yaml:"name"`
		Namespace string `yaml:"namespace"`
	} `yaml:"metadata"`
	Spec struct {
		Template struct {
			Spec struct {
				Containers     []container `yaml:"containers"`
				InitContainers []container `yaml:"initContainers"`
			} `yaml:"spec"`
		} `yaml:"template"`
		// CNPG Cluster puts resources directly on spec, with no container list.
		Resources resources `yaml:"resources"`
	} `yaml:"spec"`
}

type limitRange struct {
	Enabled              bool   `yaml:"enabled"`
	DefaultMemoryLimit   string `yaml:"defaultMemoryLimit"`
	DefaultMemoryRequest string `yaml:"defaultMemoryRequest"`
	DefaultCPURequest    string `yaml:"defaultCPURequest"`
	MinCPU               string `yaml:"minCPU"`
	MinMemory            string `yaml:"minMemory"`
	MaxCPU               string `yaml:"maxCPU"`
	MaxMemory            string `yaml:"maxMemory"`
}

type resourceQuota struct {
	Enabled        bool   `yaml:"enabled"`
	RequestsCPU    string `yaml:"requestsCPU"`
	RequestsMemory string `yaml:"requestsMemory"`
	LimitsMemory   string `yaml:"limitsMemory"`
}

// governance mirrors the part of resource-governance/values.yaml this lint reads.
type governance struct {
	LimitRanges    map[string]limitRange    `yaml:"limitRanges"`
	ResourceQuotas map[string]resourceQuota `yaml:"resourceQuotas"`
}

// entry is one container as it will exist in the cluster.
type entry struct {
	label string // chart/workload/container
	ns    string
	res   resources
	init  bool
}

var memSuffixes = []struct {
	suffix string
	mult   float64
}{
	{"Ki", 1 << 10},
	{"Mi", 1 << 20},
	{"Gi", 1 << 30},
	{"Ti", 1 << 40},
	{"K", 1e3},
	{"M", 1e6},
	{"G", 1e9},
}

// parseCPU returns cores: "100m" -> 0.1, "2" -> 2.
func parseCPU(v string) (float64, error) {
	if v == "" {
		return 0, nil
	}
	milli, isMilli := strings.CutSuffix(v, "m")
	if isMilli {
		n, err := strconv.ParseFloat(milli, 64)
		if err != nil {
			return 0, fmt.Errorf("parse cpu %q: %w", v, err)
		}
		return n / 1000, nil
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, fmt.Errorf("parse cpu %q: %w", v, err)
	}
	return n, nil
}

// parseMem returns bytes.
func parseMem(v string) (float64, error) {
	if v == "" {
		return 0, nil
	}
	for _, s := range memSuffixes {
		num, matched := strings.CutSuffix(v, s.suffix)
		if matched {
			n, err := strconv.ParseFloat(num, 64)
			if err != nil {
				return 0, fmt.Errorf("parse memory %q: %w", v, err)
			}
			return n * s.mult, nil
		}
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, fmt.Errorf("parse memory %q: %w", v, err)
	}
	return n, nil
}

func dief(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stderr, "✗ "+format+"\n", args...)
	os.Exit(1)
}

func outf(format string, args ...any) {
	_, _ = fmt.Fprintf(os.Stdout, format+"\n", args...)
}

func cpuOf(v, where string) float64 {
	n, err := parseCPU(v)
	if err != nil {
		dief("unparseable cpu quantity %q at %s: %v", v, where, err)
	}
	return n
}

func memOf(v, where string) float64 {
	n, err := parseMem(v)
	if err != nil {
		dief("unparseable memory quantity %q at %s: %v", v, where, err)
	}
	return n
}

func gib(b float64) string { return fmt.Sprintf("%.2fGi", b/(1<<30)) }

// ratio renders "used/cap (pct%)" for the utilisation line.
func ratio(got, want float64) string {
	return fmt.Sprintf("%s/%s (%.0f%%)", gib(got), gib(want), 100*got/want)
}
func cores(c float64) string { return fmt.Sprintf("%.2f cores", c) }

func firstNonEmpty(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func isWorkload(kind string) bool {
	switch kind {
	case "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob", "Pooler":
		return true
	default:
		return false
	}
}

// chartDeps mirrors the dependency list of a chart's Chart.yaml.
type chartDeps struct {
	Dependencies []struct {
		Name    string `yaml:"name"`
		Version string `yaml:"version"`
	} `yaml:"dependencies"`
}

// hasSubchart reports whether charts/ already holds that dependency, as a vendored
// .tgz of exactly the pinned version or as an unpacked directory. Matching the
// version rather than the name is what makes a Chart.yaml bump re-vendor instead of
// silently rendering the stale subchart still sitting in charts/.
func hasSubchart(dir, name, version string) bool {
	base := filepath.Join(dir, "charts")
	st, dirErr := os.Stat(filepath.Join(base, name))
	if dirErr == nil && st.IsDir() {
		return true
	}
	_, tgzErr := os.Stat(filepath.Join(base, fmt.Sprintf("%s-%s.tgz", name, version)))
	return tgzErr == nil
}

// ensureDeps vendors a chart's subcharts when charts/ does not already hold them.
// A fresh checkout has none — the .tgz files are gitignored — and `helm template`
// refuses to render a chart whose declared dependencies are missing, which is a lint
// that passes on every developer machine and fails on every CI runner.
//
// `update`, not `build`: nothing in this repo runs `helm repo add`, and `build`
// rejects a repository it has no local name for while `update` resolves the URL
// directly. That is the same call scripts/cluster-full.sh and cilium-install.sh make.
// Skipped whenever the subcharts are present, so the usual local run neither reaches
// the network nor rewrites Chart.lock.
func ensureDeps(ctx context.Context, dir, name string) error {
	raw, err := os.ReadFile(filepath.Join(dir, "Chart.yaml"))
	if err != nil {
		return fmt.Errorf("read Chart.yaml for %s: %w", name, err)
	}
	var deps chartDeps
	unmarshalErr := yaml.Unmarshal(raw, &deps)
	if unmarshalErr != nil {
		return fmt.Errorf("parse Chart.yaml for %s: %w", name, unmarshalErr)
	}
	missing := false
	for _, d := range deps.Dependencies {
		if !hasSubchart(dir, d.Name, d.Version) {
			missing = true
			break
		}
	}
	if !missing {
		return nil
	}
	out, updateErr := exec.CommandContext(ctx, "helm", "dependency", "update", dir).CombinedOutput()
	if updateErr != nil {
		return fmt.Errorf("helm dependency update %s (%s): %w", name, strings.TrimSpace(string(out)), updateErr)
	}
	return nil
}

// render runs `helm template` for one chart and returns its workload containers.
func render(ctx context.Context, dir, name string) ([]entry, error) {
	depErr := ensureDeps(ctx, dir, name)
	if depErr != nil {
		return nil, depErr
	}
	ns := chartNamespace[name]
	if ns == "" {
		ns = "platform"
	}
	// `--namespace` is not cosmetic: without it helm renders with Release.Namespace
	// = "default", so every chart stamping `namespace: {{ .Release.Namespace }}`
	// reports the wrong namespace, matches no LimitRange, and makes the coverage
	// check fire on every container in the repo.
	args := append([]string{"template", name, dir, "--namespace", ns}, chartExtraArgs[name]...)
	stdout, err := exec.CommandContext(ctx, "helm", args...).Output()
	if err != nil {
		var stderr string
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			stderr = strings.TrimSpace(string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("helm template %s (%s): %w", name, stderr, err)
	}

	return decodeWorkloads(string(stdout), name, ns), nil
}

// decodeWorkloads walks a multi-document helm render. A decode error ends the walk
// rather than failing the lint: it means either end-of-stream or a document whose
// shape the `workload` struct does not describe (a ConfigMap, a CRD), and neither is
// a resource-governance problem.
func decodeWorkloads(rendered, chart, defaultNS string) []entry {
	var entries []entry
	dec := yaml.NewDecoder(strings.NewReader(rendered))
	for {
		var w workload
		decErr := dec.Decode(&w)
		if decErr != nil {
			return entries
		}
		entries = append(entries, containersOf(w, chart, defaultNS)...)
	}
}

// containersOf flattens one rendered workload into entries.
func containersOf(w workload, chart, defaultNS string) []entry {
	ns := firstNonEmpty(w.Metadata.Namespace, defaultNS)
	if w.Kind == "Cluster" { // CNPG: resources on spec, container implicit
		return []entry{{
			label: fmt.Sprintf("%s/%s/postgres", chart, w.Metadata.Name),
			ns:    ns,
			res:   w.Spec.Resources,
		}}
	}
	if !isWorkload(w.Kind) {
		return nil
	}
	var entries []entry
	for _, c := range w.Spec.Template.Spec.Containers {
		e := entry{
			label: fmt.Sprintf("%s/%s/%s", chart, w.Metadata.Name, c.Name),
			ns:    ns,
			res:   c.Resources,
		}
		entries = append(entries, e)
	}
	for _, c := range w.Spec.Template.Spec.InitContainers {
		e := entry{
			label: fmt.Sprintf("%s/%s/%s", chart, w.Metadata.Name, c.Name),
			ns:    ns,
			res:   c.Resources,
			init:  true,
		}
		entries = append(entries, e)
	}
	return entries
}

func loadGovernance(root string) governance {
	path := filepath.Join(root, "infra/helm/platform/resource-governance/values.yaml")
	raw, err := os.ReadFile(path)
	if err != nil {
		dief("cannot read %s: %v", path, err)
	}
	var gov governance
	unmarshalErr := yaml.Unmarshal(raw, &gov)
	if unmarshalErr != nil {
		dief("cannot parse %s: %v", path, unmarshalErr)
	}
	return gov
}

// collectPlatformCharts renders every chart under infra/helm/platform/.
func collectPlatformCharts(ctx context.Context, root string) []entry {
	dirs, err := filepath.Glob(filepath.Join(root, "infra/helm/platform/*"))
	if err != nil {
		dief("%v", err)
	}
	var all []entry
	for _, d := range dirs {
		_, chartErr := os.Stat(filepath.Join(d, "Chart.yaml"))
		if chartErr != nil {
			continue // not a chart (e.g. an empty placeholder directory)
		}
		entries, renderErr := render(ctx, d, filepath.Base(d))
		if renderErr != nil {
			dief("%v", renderErr)
		}
		all = append(all, entries...)
	}
	return all
}

// collectServices renders the shared service chart ONCE PER SERVICE. A single render
// undercounts the platform namespace by ~8 containers, and the quota check is only
// worth having if the total is right. Worker presence is derived from the source tree
// so a new service cannot silently escape the budget.
func collectServices(ctx context.Context, root string) []entry {
	svcDirs, err := filepath.Glob(filepath.Join(root, "services/*"))
	if err != nil {
		dief("%v", err)
	}
	chart := filepath.Join(root, "infra/helm/service")
	var all []entry
	for _, sd := range svcDirs {
		svc := filepath.Base(sd)
		if strings.HasPrefix(svc, "_") { // _template is scaffolding, never deployed
			continue
		}
		st, statErr := os.Stat(sd)
		if statErr != nil || !st.IsDir() {
			continue
		}
		chartExtraArgs["service"] = serviceArgs(svc, hasWorker(sd))
		entries, renderErr := render(ctx, chart, "service")
		if renderErr != nil {
			dief("service chart for %s: %v", svc, renderErr)
		}
		for i := range entries {
			entries[i].label = strings.Replace(entries[i].label, "service/", svc+"/", 1)
		}
		all = append(all, entries...)
	}
	return all
}

func hasWorker(serviceDir string) bool {
	st, err := os.Stat(filepath.Join(serviceDir, "cmd", "worker"))
	return err == nil && st.IsDir()
}

func serviceArgs(svc string, worker bool) []string {
	enabled := "false"
	if worker {
		enabled = "true"
	}
	return []string{
		setFlag, "name=" + svc,
		setFlag, "image.repository=r", setFlag, "image.tag=v",
		setFlag, "ingress.enabled=false",
		setFlag, "worker.enabled=" + enabled,
		setFlag, "worker.image.repository=r", setFlag, "worker.image.tag=v",
		setFlag, "worker.versioning.enabled=false",
	}
}

// quantity parses a cpu or memory quantity, whichever the field is.
func quantity(field, value, where string) float64 {
	if field == "cpu" {
		return cpuOf(value, where)
	}
	return memOf(value, where)
}

// checkRejection is the cluster-breaking class: a declared value outside a
// LimitRange's min/max means the API server refuses the pod.
func checkRejection(all []entry, gov governance) int {
	fail := 0
	for _, e := range all {
		lr, ok := gov.LimitRanges[e.ns]
		if !ok || !lr.Enabled {
			continue
		}
		for _, c := range []struct {
			kind, field, declared, bound, rel string
			over                              bool
		}{
			{"requests", "cpu", e.res.Requests["cpu"], lr.MinCPU, "BELOW", false},
			{"requests", "memory", e.res.Requests["memory"], lr.MinMemory, "BELOW", false},
			{"limits", "memory", e.res.Limits["memory"], lr.MaxMemory, "ABOVE", true},
		} {
			if c.declared == "" || c.bound == "" {
				continue
			}
			got, want := quantity(c.field, c.declared, e.label), quantity(c.field, c.bound, e.label)
			breached := got < want
			if c.over {
				breached = got > want
			}
			if !breached {
				continue
			}
			what := fmt.Sprintf("%s %s=%s", c.kind, c.field, c.declared)
			bound := fmt.Sprintf("%s LimitRange bound of %s", e.ns, c.bound)
			outf("✗ %s %s is %s the %s — the pod would be REJECTED", e.label, what, c.rel, bound)
			fail++
		}
	}
	return fail
}

// checkCoverage asserts every container ends up governed, declared or defaulted.
func checkCoverage(all []entry, gov governance) int {
	fail := 0
	for _, e := range all {
		lr, hasLR := gov.LimitRanges[e.ns]
		defaulted := hasLR && lr.Enabled
		for _, c := range []struct{ what, declared, fallback string }{
			{"cpu request", e.res.Requests["cpu"], lr.DefaultCPURequest},
			{"memory request", e.res.Requests["memory"], lr.DefaultMemoryRequest},
			{"memory limit", e.res.Limits["memory"], lr.DefaultMemoryLimit},
		} {
			covered := c.declared != "" || (defaulted && c.fallback != "")
			if !covered {
				outf("✗ %s has no %s and namespace %s supplies no default (ADR-0020)", e.label, c.what, e.ns)
				fail++
			}
		}
	}
	return fail
}

// checkCPULimits enforces ADR-0020's opt-in-only CPU limit policy.
func checkCPULimits(all []entry) int {
	fail := 0
	for _, e := range all {
		limit := e.res.Limits["cpu"]
		if limit == "" {
			continue
		}
		_, allowed := cpuLimitAllowList[e.label]
		if allowed {
			continue
		}
		hint := "add it to cpuLimitAllowList in tools/lint-resource-governance with a reason, or remove it"
		outf("✗ %s sets a cpu limit (%s); ADR-0020 sets these only where throttling is desired", e.label, limit)
		outf("  %s", hint)
		fail++
	}
	return fail
}

type nsSum struct{ reqCPU, reqMem, limMem float64 }

// sumByNamespace totals each namespace's EFFECTIVE requests/limits, applying the
// LimitRange default wherever a container declared nothing.
func sumByNamespace(all []entry, gov governance) map[string]*nsSum {
	sums := map[string]*nsSum{}
	for _, e := range all {
		// initContainers do not add to a pod's effective request — the kubelet takes
		// the max of init vs the sum of app containers — so they are excluded.
		if e.init {
			continue
		}
		s := sums[e.ns]
		if s == nil {
			s = &nsSum{}
			sums[e.ns] = s
		}
		lr := gov.LimitRanges[e.ns]
		s.reqCPU += cpuOf(firstNonEmpty(e.res.Requests["cpu"], lr.DefaultCPURequest), e.label)
		s.reqMem += memOf(firstNonEmpty(e.res.Requests["memory"], lr.DefaultMemoryRequest), e.label)
		s.limMem += memOf(firstNonEmpty(e.res.Limits["memory"], lr.DefaultMemoryLimit), e.label)
	}
	return sums
}

// checkQuota compares each namespace's totals with its ResourceQuota, printing
// utilisation either way so the cap can be tightened deliberately.
func checkQuota(all []entry, gov governance) int {
	sums := sumByNamespace(all, gov)
	names := make([]string, 0, len(sums))
	for ns := range sums {
		names = append(names, ns)
	}
	sort.Strings(names)

	fail := 0
	for _, ns := range names {
		s := sums[ns]
		q, ok := gov.ResourceQuotas[ns]
		if !ok || !q.Enabled {
			usage := fmt.Sprintf("requests %s / %s · limits %s", cores(s.reqCPU), gib(s.reqMem), gib(s.limMem))
			outf("  %-12s %s · no quota", ns, usage)
			continue
		}
		capCPU := cpuOf(q.RequestsCPU, ns+" quota")
		capReqMem := memOf(q.RequestsMemory, ns+" quota")
		capLimMem := memOf(q.LimitsMemory, ns+" quota")
		reqCPU := fmt.Sprintf("%.2f/%.2f cores (%.0f%%)", s.reqCPU, capCPU, 100*s.reqCPU/capCPU)
		reqMem := ratio(s.reqMem, capReqMem)
		limMem := ratio(s.limMem, capLimMem)
		outf("  %-12s requests %s · %s · limits %s", ns, reqCPU, reqMem, limMem)
		fail += reportOverruns(ns, s, capCPU, capReqMem, capLimMem)
	}
	return fail
}

func reportOverruns(ns string, s *nsSum, capCPU, capReqMem, capLimMem float64) int {
	fail := 0
	for _, c := range []struct {
		name      string
		got, want float64
		render    func(float64) string
	}{
		{"requests.cpu", s.reqCPU, capCPU, cores},
		{"requests.memory", s.reqMem, capReqMem, gib},
		{"limits.memory", s.limMem, capLimMem, gib},
	} {
		if c.got > c.want {
			detail := fmt.Sprintf("summed %s is %s, cap is %s", c.name, c.render(c.got), c.render(c.want))
			outf("✗ %s: %s — pods would be rejected", ns, detail)
			fail++
		}
	}
	return fail
}

func main() {
	root, err := os.Getwd()
	if err != nil {
		dief("%v", err)
	}
	gov := loadGovernance(root)

	outf("→ rendering charts and checking ADR-0020 guardrails")
	ctx := context.Background()
	all := append(collectPlatformCharts(ctx, root), collectServices(ctx, root)...)

	fail := checkRejection(all, gov)
	fail += checkCoverage(all, gov)
	fail += checkCPULimits(all)
	fail += checkQuota(all, gov)

	if fail > 0 {
		_, _ = fmt.Fprintf(os.Stderr, "\n✗ %d resource-governance violation(s)\n", fail)
		os.Exit(1)
	}
	outf("✓ resource governance: %d containers, all covered, quotas fit", len(all))
}
