# Structured runtime failures

Public engine-boundary failures use `*diagnostics.Failure`. It adds machine
readable context without discarding the underlying Go error:

```go
if err := runtime.Update(input); err != nil {
	var failure *diagnostics.Failure
	if errors.As(err, &failure) {
		log.Printf("%s: %s; %s", failure.Subsystem, failure.Operation, failure.Recovery)
	}
	return err
}
```

`Subsystem` identifies `runtime`, `host`, `renderer`, `assets`, or `frame`.
`Operation` is the boundary operation that failed. `Cause` remains available
through `errors.Is` and `errors.As`. `Recovery` is guidance, not an automatic
retry, and `Terminal` says that the current process cannot continue without a
state change or restart.

| Boundary | Current recovery guidance | Terminal when |
| --- | --- | --- |
| Runtime initialization | Correct configuration | no application, invalid configuration, plugin, or application setup prevents startup |
| Host startup/run | Correct configuration or restart application | the host cannot be acquired, initialized, or continue its event loop |
| Frame update/draw | Correct input | an application, system, or layer rejects the current frame; the caller chooses whether to pause, repair state, or stop |
| Asset load/reload | Correct input or retry | never by the asset manager alone; callers decide whether a missing/corrupt required asset is fatal |
| Reference renderer | Correct frame input or configuration | its target cannot be initialized; invalid commands/textures are recoverable after the frame is corrected |

The failure type is part of `engine/diagnostics`, alongside `Registry`. A
caller that owns a registry can call `RecordFailure(err)` to increment a stable
`failure.<subsystem>` counter. The engine keeps no hidden global failure log,
so applications retain control over privacy, retention, and telemetry.

There is no production device/surface lifecycle yet. A future renderer or host
must return the same failure shape for adapter, surface, timeout, and device
loss errors, preserving the backend cause and selecting `Retry`, `Recreate`,
or `Restart` according to its documented policy. That future work must not
turn the current WebGPU experiments into a support claim.
