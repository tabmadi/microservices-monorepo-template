// Package temporalmw is the platform-default Temporal client/worker wiring
// (ADR-0006). Every server and worker calls NewClient / NewWorker; tracing,
// data converters, and identity all come pre-configured.
package temporalmw

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"time"

	"go.temporal.io/sdk/client"
	temporaloteltracer "go.temporal.io/sdk/contrib/opentelemetry"
	"go.temporal.io/sdk/interceptor"
	tlog "go.temporal.io/sdk/log"
	"go.temporal.io/sdk/worker"
	"go.temporal.io/sdk/workflow"

	"github.com/tabmadi/microservices-monorepo-template/libs/go/observability"
)

// Address resolves the Temporal frontend host from $TEMPORAL_HOST_PORT.
func Address() string {
	v := os.Getenv("TEMPORAL_HOST_PORT")
	if v != "" {
		return v
	}
	return "temporal-frontend.platform.svc.cluster.local:7233"
}

// Namespace resolves $TEMPORAL_NAMESPACE, defaulting to "default".
func Namespace() string {
	v := os.Getenv("TEMPORAL_NAMESPACE")
	if v != "" {
		return v
	}
	return "default"
}

// NewClient dials Temporal with the platform interceptors attached.
func NewClient(serviceName string) (client.Client, error) {
	tracingInterceptor, err := temporaloteltracer.NewTracingInterceptor(temporaloteltracer.TracerOptions{})
	if err != nil {
		return nil, fmt.Errorf("temporalmw: new tracing interceptor: %w", err)
	}
	opts := client.Options{
		HostPort:     Address(),
		Namespace:    Namespace(),
		Identity:     serviceName,
		Interceptors: []interceptor.ClientInterceptor{tracingInterceptor},
		// Route the SDK's own logs through slog.Default(), which observability.Init
		// has already pointed at the OTLP log pipeline (→ Loki). The default Temporal
		// logger writes to the stdlib log package (stdout only), so without this a
		// worker's lines — "Started Worker", task failures, panics — never reach Loki
		// and the service looks logless there. Callers run obs.Init before NewClient,
		// so slog.Default() is the OTLP fan-out by the time we dial.
		Logger: tlog.NewStructuredLogger(slog.Default()),
	}
	// Bounded startup retry: on a cold cluster the frontend may not be reachable
	// yet. Retry instead of returning on the first miss (the caller panics on
	// error → CrashLoopBackOff with a growing delay). Runtime blips are handled by
	// the SDK's own reconnection plus the /readyz gate, not here.
	var c client.Client
	err = retry(
		func() error {
			var derr error
			c, derr = client.Dial(opts)
			if derr != nil {
				return fmt.Errorf("temporalmw: dial: %w", derr)
			}
			return nil
		},
	)
	if err != nil {
		return nil, err
	}
	// Auto-register the /readyz check for this dependency (ADR-0011).
	observability.RegisterReadinessCheck(
		"temporal",
		func(ctx context.Context) error {
			_, herr := c.CheckHealth(ctx, &client.CheckHealthRequest{})
			if herr != nil {
				return fmt.Errorf("temporalmw: health: %w", herr)
			}
			return nil
		},
	)
	return c, nil
}

// retry calls fn until it succeeds or a ~60s budget elapses, backing off 500ms→5s
// between attempts. Returns fn's last error on give-up.
func retry(fn func() error) error {
	const budget = 60 * time.Second
	deadline := time.Now().Add(budget)
	delay := 500 * time.Millisecond
	for {
		err := fn()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return err
		}
		time.Sleep(delay)
		if delay < 5*time.Second {
			delay *= 2
		}
	}
}

// stopTimeout resolves how long a worker waits for in-flight Activities to finish
// after SIGTERM, from $TEMPORAL_WORKER_STOP_TIMEOUT (a Go duration).
//
// The SDK default is 0s — meaning the worker does NOT wait, and every Activity
// still executing when a pod is rolled is abandoned until its
// StartToCloseTimeout expires and it is retried elsewhere. On a rolling deploy
// that is a burst of avoidable retries and, for a non-idempotent-looking
// Activity, a burst of duplicate work. The Helm chart sets this and derives the
// pod's terminationGracePeriodSeconds from it, so kubelet always waits strictly
// longer than the worker does (infra/helm/service/values.yaml).
func stopTimeout() time.Duration {
	v := os.Getenv("TEMPORAL_WORKER_STOP_TIMEOUT")
	if v == "" {
		return 25 * time.Second
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		slog.Warn("bad TEMPORAL_WORKER_STOP_TIMEOUT, using default", "value", v, "error", err)
		return 25 * time.Second
	}
	return d
}

// deploymentOptions builds the Worker Deployment Versioning config (ADR-0006)
// from the environment the chart injects. Versioning is ON whenever BOTH
// $TEMPORAL_DEPLOYMENT_NAME and $TEMPORAL_WORKER_BUILD_ID are set; with either
// missing the worker polls unversioned, which is what local `go run` and the
// tests want.
//
// DefaultVersioningBehavior is Pinned: an execution runs start-to-finish on the
// Deployment Version that began it, so a deploy cannot break a Workflow that is
// already in flight and no workflow.GetVersion patching is required. Workflows
// that must instead follow the newest code opt out individually by returning
// AutoUpgrade — and those, per ADR-0006, owe a versioning plan and replay tests.
func deploymentOptions() worker.DeploymentOptions {
	name, buildID := os.Getenv("TEMPORAL_DEPLOYMENT_NAME"), os.Getenv("TEMPORAL_WORKER_BUILD_ID")
	if name == "" || buildID == "" {
		return worker.DeploymentOptions{}
	}
	return worker.DeploymentOptions{
		UseVersioning: true,
		Version: worker.WorkerDeploymentVersion{
			DeploymentName: name,
			BuildID:        buildID,
		},
		DefaultVersioningBehavior: workflow.VersioningBehaviorPinned,
	}
}

// NewWorker constructs a Temporal worker with the platform-default options.
//
// EnableSessionWorker is deliberately NOT set. It was on here historically while
// nothing in the repo ever opened a session (no CreateSession / workflow.Session
// call exists), and the SDK forbids combining it with Worker Deployment
// Versioning — "Cannot be enabled at the same time as
// WorkerOptions.EnableSessionWorker". A service that genuinely needs sessions
// therefore has to opt out of versioning explicitly rather than inherit both.
func NewWorker(c client.Client, taskQueue string) worker.Worker {
	return worker.New(
		c,
		taskQueue,
		worker.Options{
			MaxConcurrentActivityExecutionSize: 50,
			WorkerStopTimeout:                  stopTimeout(),
			DeploymentOptions:                  deploymentOptions(),
		},
	)
}
