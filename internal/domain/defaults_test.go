package domain

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestClassifyDefaultTier(t *testing.T) {
	tests := []struct {
		field string
		want  string
	}{
		{"branch_protection", "tier_1"},
		{"delete_branch_on_merge", "tier_1"},
		{"topics_additive", "tier_1"},
		{"allow_squash_merge", "tier_2"},
		{"has_wiki", "tier_2"},
		{"made_up", "unknown"},
	}
	for _, tt := range tests {
		if got := ClassifyDefaultTier(tt.field); got != tt.want {
			t.Fatalf("ClassifyDefaultTier(%q)=%q want %q", tt.field, got, tt.want)
		}
	}
}

func TestComputeTopicsUnion(t *testing.T) {
	tests := []struct {
		name     string
		current  []string
		additive []string
		want     []string
	}{
		{name: "empty current", additive: []string{"serverkraken-onboarded"}, want: []string{"serverkraken-onboarded"}},
		{name: "append missing", current: []string{"go", "backend"}, additive: []string{"serverkraken-onboarded"}, want: []string{"go", "backend", "serverkraken-onboarded"}},
		{name: "already present", current: []string{"serverkraken-onboarded", "go"}, additive: []string{"serverkraken-onboarded"}, want: []string{"serverkraken-onboarded", "go"}},
		{name: "some present", current: []string{"a", "b"}, additive: []string{"b", "c"}, want: []string{"a", "b", "c"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ComputeTopicsUnion(tt.current, tt.additive); !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("topics=%v want %v", got, tt.want)
			}
		})
	}
}

func TestDiffBranchProtection(t *testing.T) {
	target := BranchProtectionDefaults{
		RequiredPullRequestReviews: &PullRequestReviewsDefaults{},
		RequiredStatusChecks:       json.RawMessage("null"),
		RequiredLinearHistory:      true,
		Restrictions:               json.RawMessage("null"),
	}
	tests := []struct {
		name    string
		current string
		missing bool
		want    string
	}{
		{name: "missing", missing: true, want: "reason=missing"},
		{name: "identical", current: `{
			"enforce_admins":{"enabled":false},
			"required_linear_history":{"enabled":true},
			"allow_force_pushes":{"enabled":false},
			"allow_deletions":{"enabled":false},
			"required_conversation_resolution":{"enabled":false},
			"lock_branch":{"enabled":false},
			"block_creations":{"enabled":false},
			"required_pull_request_reviews":{
			  "required_approving_review_count":0,
			  "dismiss_stale_reviews":false,
			  "require_code_owner_reviews":false,
			  "require_last_push_approval":false
			},
			"required_status_checks":null,
			"restrictions":null
		}`},
		{name: "drift", current: `{
			"enforce_admins":{"enabled":true},
			"required_linear_history":{"enabled":true},
			"required_status_checks":null,
			"required_pull_request_reviews":{"required_approving_review_count":0},
			"restrictions":null
		}`, want: "enforce_admins"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := DiffBranchProtection(json.RawMessage(tt.current), tt.missing, target)
			if err != nil {
				t.Fatal(err)
			}
			if tt.want == "" && got != "" {
				t.Fatalf("diff=%q want empty", got)
			}
			if tt.want != "" && !strings.Contains(got, tt.want) {
				t.Fatalf("diff=%q want contains %q", got, tt.want)
			}
		})
	}
	if _, err := DiffBranchProtection(json.RawMessage("{"), false, target); err == nil {
		t.Fatal("expected invalid current JSON error")
	}
}

func TestFlatDiffsAndPayloads(t *testing.T) {
	meta := RepoMetadata{
		AllowSquashMerge:         true,
		AllowMergeCommit:         true,
		AllowAutoMerge:           true,
		SquashMergeCommitTitle:   "PR_TITLE",
		SquashMergeCommitMessage: "PR_BODY",
		HasWiki:                  true,
		HasIssues:                true,
	}
	merge := MergeHygieneDefaults{
		AllowSquashMerge:         true,
		AllowMergeCommit:         false,
		AllowAutoMerge:           true,
		SquashMergeCommitTitle:   "PR_TITLE",
		SquashMergeCommitMessage: "BLANK",
	}
	settings := RepoSettingsDefaults{HasIssues: true}
	if got := strings.Join(DiffMergeHygiene(meta, merge), ","); got != "allow_merge_commit,squash_merge_commit_message" {
		t.Fatalf("merge diff=%q", got)
	}
	if got := strings.Join(DiffRepoSettings(meta, settings), ","); got != "has_wiki" {
		t.Fatalf("settings diff=%q", got)
	}
	payload, err := MergeAndRepoSettingsPatch(merge, settings)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(payload), "delete_branch_on_merge") || !strings.Contains(string(payload), `"has_issues":true`) {
		t.Fatalf("patch payload=%s", payload)
	}
	if got := string(DeleteBranchPatch(true)); got != `{"delete_branch_on_merge":true}` {
		t.Fatalf("delete patch=%s", got)
	}
	if got := string(DeleteBranchPatch(false)); got != `{"delete_branch_on_merge":false}` {
		t.Fatalf("delete patch false=%s", got)
	}
}

func TestBranchProtectionPayloadDropsTarget(t *testing.T) {
	payload, err := BranchProtectionPayload(BranchProtectionDefaults{
		Target:                     "default_branch",
		RequiredPullRequestReviews: &PullRequestReviewsDefaults{},
		RequiredStatusChecks:       json.RawMessage("null"),
		RequiredLinearHistory:      true,
		Restrictions:               json.RawMessage("null"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(payload), "_target") || !strings.Contains(string(payload), `"required_linear_history":true`) {
		t.Fatalf("payload=%s", payload)
	}
}

func TestBranchProtectionNilValues(t *testing.T) {
	target := BranchProtectionDefaults{
		RequiredPullRequestReviews: nil,
		RequiredStatusChecks:       nil,
		Restrictions:               nil,
	}
	diff, err := DiffBranchProtection(json.RawMessage(`{
	  "required_pull_request_reviews": null,
	  "required_status_checks": null,
	  "restrictions": null
	}`), false, target)
	if err != nil {
		t.Fatal(err)
	}
	if diff != "" {
		t.Fatalf("diff=%q", diff)
	}
	payload, err := BranchProtectionPayload(target)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), `"required_status_checks":null`) || !strings.Contains(string(payload), `"restrictions":null`) {
		t.Fatalf("payload=%s", payload)
	}
}

func TestBranchProtectionInvalidRawComparesAsString(t *testing.T) {
	diff, err := DiffBranchProtection(json.RawMessage(`{"required_status_checks":null}`), false, BranchProtectionDefaults{
		RequiredStatusChecks: json.RawMessage("{"),
		Restrictions:         json.RawMessage("null"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diff, "required_status_checks") {
		t.Fatalf("diff=%q", diff)
	}
}
