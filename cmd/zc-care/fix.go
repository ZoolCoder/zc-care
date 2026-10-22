package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/zoolcoder/zc-care/internal/engine"
	"github.com/zoolcoder/zc-care/internal/plan"
	"github.com/zoolcoder/zc-care/internal/security"
	"github.com/zoolcoder/zc-care/internal/sh"
)

const (
	viaDoctor      = "doctor -fix"
	securityTarget = "security"
)

// fixPlan is one action per failed check that has commands to repair it. The
// detail is the commands exactly as they run, sudo included. Every fix needs
// a yes first: each changes the machine in a way the config did not ask for.
func fixPlan(results []security.Result, r sh.Runner) plan.Plan {
	var p plan.Plan
	for _, res := range results {
		if res.OK || len(res.Fix) == 0 {
			continue
		}
		lines := make([]string, len(res.Fix))
		for i, argv := range res.Fix {
			lines[i] = security.Line(argv)
		}
		p.Add(plan.Action{
			Op: plan.OpUpdate, Target: securityTarget, Resource: res.Name,
			Detail: strings.Join(lines, "; "), Destructive: true,
			Do: func(ctx context.Context) error {
				for _, argv := range res.Fix {
					if err := r.Run(ctx, argv[0], argv[1:]...); err != nil {
						return err
					}
				}
				return nil
			},
		})
	}
	return p
}

// fixFindings plans the repairs for the failed checks, shows them, applies
// them after a yes, and re-runs the checks it repaired. A finding with no
// command stays advice in the report.
func fixFindings(ctx context.Context, results []security.Result, r sh.Runner, yes bool, stdin io.Reader, stdout, stderr io.Writer) error {
	p := fixPlan(results, r)
	if p.Empty() {
		_, err := fmt.Fprintln(stdout, "\nnothing doctor can fix on its own; the rest is advice above")
		return err
	}
	fmt.Fprintln(stdout, "\nfixes:")
	if err := p.Write(stdout); err != nil {
		return err
	}
	if !yes && !confirm(stdin, stdout, "this runs the commands above") {
		return errCancelled
	}
	fmt.Fprintln(stdout)
	outcomes, err := engine.Run(ctx, p, stdout)
	recordApply("", outcomes, viaDoctor, stderr)
	unverified, failing := stillFailing(ctx, p, r)
	err = errors.Join(err, failing)
	for _, name := range unverified {
		fmt.Fprintf(stdout, "could not verify %s\n", name)
	}
	if err == nil && len(unverified) == 0 {
		_, err = fmt.Fprintln(stdout, "fixed and verified")
	}
	return err
}

// stillFailing re-runs the security checks and names any the fixes did not
// repair, since a command that exits 0 can still leave the setting as it was.
// A repaired check that now cannot be read is neither: it is returned apart,
// as unverified.
func stillFailing(ctx context.Context, fixed plan.Plan, r sh.Runner) (unverified []string, failing error) {
	repaired := map[string]bool{}
	for _, a := range fixed.Actions {
		repaired[a.Resource] = true
	}
	var left []string
	for _, res := range security.New(r).Run(ctx) {
		switch {
		case !repaired[res.Name] || res.OK:
		case res.Unknown:
			unverified = append(unverified, res.Name)
		default:
			left = append(left, res.Name)
		}
	}
	if len(left) > 0 {
		failing = fmt.Errorf("still failing after the fix: %s", strings.Join(left, ", "))
	}
	return unverified, failing
}
