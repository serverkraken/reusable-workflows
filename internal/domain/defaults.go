package domain

import (
	"encoding/json"
	"reflect"
	"strings"
)

type RepoDefaults struct {
	SchemaVersion    int                      `json:"_schema_version"`
	BranchProtection BranchProtectionDefaults `json:"branch_protection"`
	MergeHygiene     MergeHygieneDefaults     `json:"merge_hygiene"`
	RepoSettings     RepoSettingsDefaults     `json:"repo_settings"`
	TopicsAdditive   []string                 `json:"topics_additive"`
}

type BranchProtectionDefaults struct {
	Target                         string                      `json:"_target,omitempty"`
	RequiredPullRequestReviews     *PullRequestReviewsDefaults `json:"required_pull_request_reviews"`
	RequiredStatusChecks           json.RawMessage             `json:"required_status_checks"`
	EnforceAdmins                  bool                        `json:"enforce_admins"`
	RequiredLinearHistory          bool                        `json:"required_linear_history"`
	AllowForcePushes               bool                        `json:"allow_force_pushes"`
	AllowDeletions                 bool                        `json:"allow_deletions"`
	RequiredConversationResolution bool                        `json:"required_conversation_resolution"`
	LockBranch                     bool                        `json:"lock_branch"`
	BlockCreations                 bool                        `json:"block_creations"`
	Restrictions                   json.RawMessage             `json:"restrictions"`
}

type PullRequestReviewsDefaults struct {
	RequiredApprovingReviewCount int  `json:"required_approving_review_count"`
	DismissStaleReviews          bool `json:"dismiss_stale_reviews"`
	RequireCodeOwnerReviews      bool `json:"require_code_owner_reviews"`
	RequireLastPushApproval      bool `json:"require_last_push_approval"`
}

type BranchProtectionCurrent struct {
	RequiredPullRequestReviews     *PullRequestReviewsDefaults `json:"required_pull_request_reviews"`
	RequiredStatusChecks           json.RawMessage             `json:"required_status_checks"`
	EnforceAdmins                  *EnabledFlag                `json:"enforce_admins"`
	RequiredLinearHistory          *EnabledFlag                `json:"required_linear_history"`
	AllowForcePushes               *EnabledFlag                `json:"allow_force_pushes"`
	AllowDeletions                 *EnabledFlag                `json:"allow_deletions"`
	RequiredConversationResolution *EnabledFlag                `json:"required_conversation_resolution"`
	LockBranch                     *EnabledFlag                `json:"lock_branch"`
	BlockCreations                 *EnabledFlag                `json:"block_creations"`
	Restrictions                   json.RawMessage             `json:"restrictions"`
}

type EnabledFlag struct {
	Enabled bool `json:"enabled"`
}

type MergeHygieneDefaults struct {
	AllowSquashMerge         bool   `json:"allow_squash_merge"`
	AllowMergeCommit         bool   `json:"allow_merge_commit"`
	AllowRebaseMerge         bool   `json:"allow_rebase_merge"`
	DeleteBranchOnMerge      bool   `json:"delete_branch_on_merge"`
	AllowAutoMerge           bool   `json:"allow_auto_merge"`
	SquashMergeCommitTitle   string `json:"squash_merge_commit_title"`
	SquashMergeCommitMessage string `json:"squash_merge_commit_message"`
}

type RepoSettingsDefaults struct {
	HasWiki        bool `json:"has_wiki"`
	HasProjects    bool `json:"has_projects"`
	HasIssues      bool `json:"has_issues"`
	HasDiscussions bool `json:"has_discussions"`
}

type RepoMetadata struct {
	DefaultBranch            string `json:"default_branch"`
	AllowSquashMerge         bool   `json:"allow_squash_merge"`
	AllowMergeCommit         bool   `json:"allow_merge_commit"`
	AllowRebaseMerge         bool   `json:"allow_rebase_merge"`
	DeleteBranchOnMerge      bool   `json:"delete_branch_on_merge"`
	AllowAutoMerge           bool   `json:"allow_auto_merge"`
	SquashMergeCommitTitle   string `json:"squash_merge_commit_title"`
	SquashMergeCommitMessage string `json:"squash_merge_commit_message"`
	HasWiki                  bool   `json:"has_wiki"`
	HasProjects              bool   `json:"has_projects"`
	HasIssues                bool   `json:"has_issues"`
	HasDiscussions           bool   `json:"has_discussions"`
}

type RepoDefaultsResult struct {
	DefaultsApplied bool
	Tier2Applied    bool
	Modified        []string
	WouldChange     []string
	Notices         []string
}

func ClassifyDefaultTier(field string) string {
	switch field {
	case "branch_protection", "delete_branch_on_merge", "topics_additive":
		return "tier_1"
	case "allow_squash_merge", "allow_merge_commit", "allow_rebase_merge", "allow_auto_merge",
		"squash_merge_commit_title", "squash_merge_commit_message",
		"has_wiki", "has_projects", "has_issues", "has_discussions":
		return "tier_2"
	default:
		return "unknown"
	}
}

func ComputeTopicsUnion(current, additive []string) []string {
	next := append([]string(nil), current...)
	currentSet := make(map[string]struct{}, len(current))
	for _, topic := range current {
		currentSet[topic] = struct{}{}
	}
	for _, topic := range additive {
		if _, ok := currentSet[topic]; !ok {
			next = append(next, topic)
		}
	}
	return next
}

func DiffBranchProtection(currentRaw json.RawMessage, missing bool, target BranchProtectionDefaults) (string, error) {
	if missing {
		return "reason=missing", nil
	}
	var current BranchProtectionCurrent
	if err := json.Unmarshal(currentRaw, &current); err != nil {
		return "", err
	}

	currentValues := normalizeBranchProtectionCurrent(current)
	targetValues := normalizeBranchProtectionTarget(target)
	keys := []string{
		"enforce_admins",
		"required_linear_history",
		"allow_force_pushes",
		"allow_deletions",
		"required_conversation_resolution",
		"lock_branch",
		"block_creations",
		"required_status_checks",
		"required_pull_request_reviews",
		"restrictions",
	}
	diff := make([]string, 0)
	for _, key := range keys {
		if !reflect.DeepEqual(currentValues[key], targetValues[key]) {
			diff = append(diff, key)
		}
	}
	if len(diff) == 0 {
		return "", nil
	}
	return "reason=drift fields=" + strings.Join(diff, ","), nil
}

func DiffMergeHygiene(current RepoMetadata, target MergeHygieneDefaults) []string {
	values := []struct {
		name string
		got  any
		want any
	}{
		{"allow_squash_merge", current.AllowSquashMerge, target.AllowSquashMerge},
		{"allow_merge_commit", current.AllowMergeCommit, target.AllowMergeCommit},
		{"allow_rebase_merge", current.AllowRebaseMerge, target.AllowRebaseMerge},
		{"allow_auto_merge", current.AllowAutoMerge, target.AllowAutoMerge},
		{"squash_merge_commit_title", current.SquashMergeCommitTitle, target.SquashMergeCommitTitle},
		{"squash_merge_commit_message", current.SquashMergeCommitMessage, target.SquashMergeCommitMessage},
	}
	return diffValues(values)
}

func DiffRepoSettings(current RepoMetadata, target RepoSettingsDefaults) []string {
	values := []struct {
		name string
		got  any
		want any
	}{
		{"has_wiki", current.HasWiki, target.HasWiki},
		{"has_projects", current.HasProjects, target.HasProjects},
		{"has_issues", current.HasIssues, target.HasIssues},
		{"has_discussions", current.HasDiscussions, target.HasDiscussions},
	}
	return diffValues(values)
}

func BranchProtectionPayload(target BranchProtectionDefaults) ([]byte, error) {
	payload := struct {
		RequiredPullRequestReviews     *PullRequestReviewsDefaults `json:"required_pull_request_reviews"`
		RequiredStatusChecks           json.RawMessage             `json:"required_status_checks"`
		EnforceAdmins                  bool                        `json:"enforce_admins"`
		RequiredLinearHistory          bool                        `json:"required_linear_history"`
		AllowForcePushes               bool                        `json:"allow_force_pushes"`
		AllowDeletions                 bool                        `json:"allow_deletions"`
		RequiredConversationResolution bool                        `json:"required_conversation_resolution"`
		LockBranch                     bool                        `json:"lock_branch"`
		BlockCreations                 bool                        `json:"block_creations"`
		Restrictions                   json.RawMessage             `json:"restrictions"`
	}{
		RequiredPullRequestReviews:     target.RequiredPullRequestReviews,
		RequiredStatusChecks:           rawOrNull(target.RequiredStatusChecks),
		EnforceAdmins:                  target.EnforceAdmins,
		RequiredLinearHistory:          target.RequiredLinearHistory,
		AllowForcePushes:               target.AllowForcePushes,
		AllowDeletions:                 target.AllowDeletions,
		RequiredConversationResolution: target.RequiredConversationResolution,
		LockBranch:                     target.LockBranch,
		BlockCreations:                 target.BlockCreations,
		Restrictions:                   rawOrNull(target.Restrictions),
	}
	return json.Marshal(payload)
}

func MergeAndRepoSettingsPatch(merge MergeHygieneDefaults, settings RepoSettingsDefaults) ([]byte, error) {
	payload := struct {
		AllowSquashMerge         bool   `json:"allow_squash_merge"`
		AllowMergeCommit         bool   `json:"allow_merge_commit"`
		AllowRebaseMerge         bool   `json:"allow_rebase_merge"`
		AllowAutoMerge           bool   `json:"allow_auto_merge"`
		SquashMergeCommitTitle   string `json:"squash_merge_commit_title"`
		SquashMergeCommitMessage string `json:"squash_merge_commit_message"`
		HasWiki                  bool   `json:"has_wiki"`
		HasProjects              bool   `json:"has_projects"`
		HasIssues                bool   `json:"has_issues"`
		HasDiscussions           bool   `json:"has_discussions"`
	}{
		AllowSquashMerge:         merge.AllowSquashMerge,
		AllowMergeCommit:         merge.AllowMergeCommit,
		AllowRebaseMerge:         merge.AllowRebaseMerge,
		AllowAutoMerge:           merge.AllowAutoMerge,
		SquashMergeCommitTitle:   merge.SquashMergeCommitTitle,
		SquashMergeCommitMessage: merge.SquashMergeCommitMessage,
		HasWiki:                  settings.HasWiki,
		HasProjects:              settings.HasProjects,
		HasIssues:                settings.HasIssues,
		HasDiscussions:           settings.HasDiscussions,
	}
	return json.Marshal(payload)
}

func DeleteBranchPatch(value bool) []byte {
	if value {
		return []byte(`{"delete_branch_on_merge":true}`)
	}
	return []byte(`{"delete_branch_on_merge":false}`)
}

func normalizeBranchProtectionCurrent(current BranchProtectionCurrent) map[string]any {
	values := map[string]any{
		"enforce_admins":                   enabled(current.EnforceAdmins),
		"required_linear_history":          enabled(current.RequiredLinearHistory),
		"allow_force_pushes":               enabled(current.AllowForcePushes),
		"allow_deletions":                  enabled(current.AllowDeletions),
		"required_conversation_resolution": enabled(current.RequiredConversationResolution),
		"lock_branch":                      enabled(current.LockBranch),
		"block_creations":                  enabled(current.BlockCreations),
		"required_status_checks":           rawValue(current.RequiredStatusChecks),
		"required_pull_request_reviews":    pullRequestValue(current.RequiredPullRequestReviews),
		"restrictions":                     rawValue(current.Restrictions),
	}
	return values
}

func normalizeBranchProtectionTarget(target BranchProtectionDefaults) map[string]any {
	values := map[string]any{
		"enforce_admins":                   target.EnforceAdmins,
		"required_linear_history":          target.RequiredLinearHistory,
		"allow_force_pushes":               target.AllowForcePushes,
		"allow_deletions":                  target.AllowDeletions,
		"required_conversation_resolution": target.RequiredConversationResolution,
		"lock_branch":                      target.LockBranch,
		"block_creations":                  target.BlockCreations,
		"required_status_checks":           rawValue(target.RequiredStatusChecks),
		"required_pull_request_reviews":    pullRequestValue(target.RequiredPullRequestReviews),
		"restrictions":                     rawValue(target.Restrictions),
	}
	return values
}

func pullRequestValue(reviews *PullRequestReviewsDefaults) any {
	if reviews == nil {
		return nil
	}
	return map[string]any{
		"required_approving_review_count": reviews.RequiredApprovingReviewCount,
		"dismiss_stale_reviews":           reviews.DismissStaleReviews,
		"require_code_owner_reviews":      reviews.RequireCodeOwnerReviews,
		"require_last_push_approval":      reviews.RequireLastPushApproval,
	}
}

func rawValue(raw json.RawMessage) any {
	raw = rawOrNull(raw)
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return string(raw)
	}
	return value
}

func rawOrNull(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return json.RawMessage("null")
	}
	return raw
}

func enabled(flag *EnabledFlag) bool {
	return flag != nil && flag.Enabled
}

func diffValues(values []struct {
	name string
	got  any
	want any
}) []string {
	diff := make([]string, 0)
	for _, value := range values {
		if !reflect.DeepEqual(value.got, value.want) {
			diff = append(diff, value.name)
		}
	}
	return diff
}
