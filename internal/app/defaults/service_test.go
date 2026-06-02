package defaults

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/serverkraken/reusable-workflows/internal/domain"
)

func TestApplyLiveModeAppliesAllTiersAndMutatesLock(t *testing.T) {
	gh := &fakeGitHub{
		meta: domain.RepoMetadata{
			DefaultBranch:            "main",
			AllowSquashMerge:         true,
			AllowMergeCommit:         true,
			DeleteBranchOnMerge:      false,
			SquashMergeCommitTitle:   "PR_TITLE",
			SquashMergeCommitMessage: "PR_BODY",
			HasWiki:                  true,
			HasIssues:                true,
		},
		protectionMissing: true,
		topics:            []string{"go"},
	}
	store := &fakeStore{defaults: testDefaults(), targetExists: true, lockExists: true}
	res, err := (Service{
		GitHub: gh,
		Store:  store,
		Now:    func() time.Time { return time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC) },
	}).Apply(context.Background(), Request{
		CatalogPath: "catalog",
		Repo:        "o/r",
		TargetPath:  "target",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"branch_protection", "delete_branch_on_merge", "topics", "merge_hygiene", "repo_settings"}
	if !res.DefaultsApplied || !res.Tier2Applied || !reflect.DeepEqual(res.Modified, want) {
		t.Fatalf("result=%+v want modified %v", res, want)
	}
	if gh.updatedProtection == "" || !strings.Contains(gh.updatedProtection, "branches/main/protection") {
		t.Fatalf("updatedProtection=%q", gh.updatedProtection)
	}
	if got := string(gh.patchPayloads[0]); got != `{"delete_branch_on_merge":true}` {
		t.Fatalf("delete patch=%s", got)
	}
	if !strings.Contains(string(gh.patchPayloads[1]), `"has_wiki":false`) {
		t.Fatalf("tier2 patch=%s", gh.patchPayloads[1])
	}
	if !reflect.DeepEqual(gh.replacedTopics, []string{"go", "serverkraken-onboarded"}) {
		t.Fatalf("topics=%v", gh.replacedTopics)
	}
	if store.marker != "2026-06-02T12:00:00Z" {
		t.Fatalf("marker=%q", store.marker)
	}
}

func TestApplyPreservesPrevMarkerAndSkipsTier2(t *testing.T) {
	gh := &fakeGitHub{
		meta: domain.RepoMetadata{
			DefaultBranch:       "main",
			DeleteBranchOnMerge: true,
			AllowMergeCommit:    true,
			HasIssues:           true,
			HasWiki:             true,
		},
		protectionRaw: cleanProtection(t),
		topics:        []string{"serverkraken-onboarded"},
	}
	store := &fakeStore{defaults: testDefaults(), targetExists: true, lockExists: true}
	res, err := (Service{GitHub: gh, Store: store}).Apply(context.Background(), Request{
		CatalogPath: "catalog",
		Repo:        "o/r",
		TargetPath:  "target",
		PrevMarker:  "2026-04-01T00:00:00Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Tier2Applied || len(res.Modified) != 0 {
		t.Fatalf("result=%+v", res)
	}
	if len(gh.patchPayloads) != 0 {
		t.Fatalf("unexpected patches=%s", gh.patchPayloads)
	}
	if store.marker != "2026-04-01T00:00:00Z" {
		t.Fatalf("marker=%q", store.marker)
	}
}

func TestApplyDryRunPlansWithoutMutations(t *testing.T) {
	gh := &fakeGitHub{
		meta: domain.RepoMetadata{
			DefaultBranch:            "main",
			AllowSquashMerge:         true,
			AllowMergeCommit:         true,
			DeleteBranchOnMerge:      false,
			SquashMergeCommitTitle:   "PR_TITLE",
			SquashMergeCommitMessage: "PR_BODY",
			HasWiki:                  true,
			HasIssues:                true,
		},
		protectionMissing: true,
		topics:            []string{"go"},
	}
	store := &fakeStore{defaults: testDefaults(), targetExists: true, lockExists: true}
	res, err := (Service{
		GitHub: gh,
		Store:  store,
		Now:    func() time.Time { return time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC) },
	}).Apply(context.Background(), Request{CatalogPath: "catalog", Repo: "o/r", TargetPath: "target", DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"branch_protection", "delete_branch_on_merge", "topics", "merge_hygiene", "repo_settings"}
	if res.DefaultsApplied || res.Tier2Applied || !reflect.DeepEqual(res.WouldChange, want) {
		t.Fatalf("result=%+v", res)
	}
	if gh.updatedProtection != "" || len(gh.patchPayloads) != 0 || gh.replacedTopics != nil || store.marker != "" {
		t.Fatalf("mutations happened: gh=%+v store=%+v", gh, store)
	}
	if got := strings.Join(res.Notices, "\n"); !strings.Contains(got, "would PUT branch protection") || !strings.Contains(got, "would mutate lock") {
		t.Fatalf("notices=%q", got)
	}
}

func TestApplyHandlesNoLockAndReadFallbacks(t *testing.T) {
	gh := &fakeGitHub{
		meta:          domain.RepoMetadata{DefaultBranch: "main", DeleteBranchOnMerge: true, HasIssues: true},
		protectionErr: errors.New("branch protection read failed"),
		topicsErr:     errors.New("topics forbidden"),
	}
	store := &fakeStore{defaults: testDefaults(), targetExists: true}
	res, err := (Service{GitHub: gh, Store: store}).Apply(context.Background(), Request{
		CatalogPath: "catalog",
		Repo:        "o/r",
		TargetPath:  "target",
		PrevMarker:  "marker",
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(res.Modified, []string{"branch_protection", "topics"}) {
		t.Fatalf("modified=%v", res.Modified)
	}
	if store.marker != "" {
		t.Fatalf("lock mutated without lock: %q", store.marker)
	}
}

func TestApplyDefaultBranchFallbackAndTopicMutationError(t *testing.T) {
	gh := &fakeGitHub{
		meta: domain.RepoMetadata{
			DeleteBranchOnMerge: true,
			HasIssues:           true,
		},
		protectionRaw:    cleanProtectionNoReviews(),
		topics:           []string{"go"},
		replaceTopicsErr: errors.New("topics failed"),
	}
	store := &fakeStore{defaults: testDefaults(), targetExists: true}
	_, err := (Service{GitHub: gh, Store: store}).Apply(context.Background(), Request{
		CatalogPath: "catalog",
		Repo:        "o/r",
		TargetPath:  "target",
		PrevMarker:  "marker",
	})
	if err == nil || !strings.Contains(err.Error(), "topics failed") {
		t.Fatalf("err=%v", err)
	}
	if gh.branchSeen != "main" {
		t.Fatalf("branchSeen=%q", gh.branchSeen)
	}
}

func TestApplyErrors(t *testing.T) {
	tests := []struct {
		name string
		req  Request
		svc  Service
		want string
	}{
		{name: "missing repo", req: Request{CatalogPath: "c", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{}, Store: &fakeStore{targetExists: true}}, want: "usage"},
		{name: "missing target", req: Request{CatalogPath: "c", Repo: "o/r"}, svc: Service{GitHub: &fakeGitHub{}, Store: &fakeStore{targetExists: true}}, want: "usage"},
		{name: "missing catalog", req: Request{Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{}, Store: &fakeStore{targetExists: true}}, want: "catalog path"},
		{name: "no github", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{Store: &fakeStore{targetExists: true}}, want: "GitHub port"},
		{name: "no store", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{}}, want: "store port"},
		{name: "target stat error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{}, Store: &fakeStore{targetErr: errors.New("stat bad")}}, want: "stat bad"},
		{name: "target missing", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{}, Store: &fakeStore{}}, want: "target path"},
		{name: "config error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{}, Store: &fakeStore{targetExists: true, readErr: errors.New("bad config")}}, want: "bad config"},
		{name: "metadata error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{metaErr: errors.New("forbidden")}, Store: &fakeStore{defaults: testDefaults(), targetExists: true}}, want: "failed to fetch"},
		{name: "branch diff error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{meta: domain.RepoMetadata{DefaultBranch: "main"}, protectionRaw: json.RawMessage("{")}, Store: &fakeStore{defaults: testDefaults(), targetExists: true}}, want: "unexpected end"},
		{name: "mutating error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{meta: domain.RepoMetadata{DefaultBranch: "main"}, protectionMissing: true, updateProtectionErr: errors.New("boom")}, Store: &fakeStore{defaults: testDefaults(), targetExists: true}}, want: "boom"},
		{name: "branch payload error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{meta: domain.RepoMetadata{DefaultBranch: "main"}, protectionMissing: true}, Store: &fakeStore{defaults: invalidBranchPayloadDefaults(), targetExists: true}}, want: "error calling MarshalJSON"},
		{name: "tier2 patch error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: &fakeGitHub{meta: domain.RepoMetadata{DefaultBranch: "main", DeleteBranchOnMerge: true, AllowMergeCommit: true, HasIssues: true}, protectionRaw: cleanProtectionNoReviews(), topics: []string{"serverkraken-onboarded"}, patchErr: errors.New("patch failed")}, Store: &fakeStore{defaults: testDefaults(), targetExists: true}}, want: "patch failed"},
		{name: "lock exists error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: cleanFakeGitHub(), Store: &fakeStore{defaults: testDefaults(), targetExists: true, lockExistsErr: errors.New("lock stat bad")}}, want: "lock stat bad"},
		{name: "lock error", req: Request{CatalogPath: "c", Repo: "o/r", TargetPath: "t"}, svc: Service{GitHub: cleanFakeGitHub(), Store: &fakeStore{defaults: testDefaults(), targetExists: true, lockExists: true, lockErr: errors.New("lock bad")}}, want: "lock bad"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := tt.svc.Apply(context.Background(), tt.req)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Fatalf("err=%v want contains %q", err, tt.want)
			}
		})
	}
}

func TestCategoriesCSV(t *testing.T) {
	if got := CategoriesCSV([]string{"a", "b"}); got != "a,b" {
		t.Fatalf("csv=%q", got)
	}
}

func cleanFakeGitHub() *fakeGitHub {
	return &fakeGitHub{
		meta: domain.RepoMetadata{
			DefaultBranch:       "main",
			DeleteBranchOnMerge: true,
			HasIssues:           true,
		},
		protectionRaw: cleanProtectionNoReviews(),
		topics:        []string{"serverkraken-onboarded"},
	}
}

func invalidBranchPayloadDefaults() domain.RepoDefaults {
	cfg := testDefaults()
	cfg.BranchProtection.RequiredStatusChecks = json.RawMessage("{")
	return cfg
}

func testDefaults() domain.RepoDefaults {
	return domain.RepoDefaults{
		BranchProtection: domain.BranchProtectionDefaults{
			RequiredStatusChecks:       json.RawMessage("null"),
			RequiredLinearHistory:      true,
			RequiredPullRequestReviews: &domain.PullRequestReviewsDefaults{},
			Restrictions:               json.RawMessage("null"),
		},
		MergeHygiene: domain.MergeHygieneDefaults{
			AllowSquashMerge:         true,
			DeleteBranchOnMerge:      true,
			AllowAutoMerge:           true,
			SquashMergeCommitTitle:   "PR_TITLE",
			SquashMergeCommitMessage: "BLANK",
		},
		RepoSettings:   domain.RepoSettingsDefaults{HasIssues: true},
		TopicsAdditive: []string{"serverkraken-onboarded"},
	}
}

func cleanProtection(t *testing.T) json.RawMessage {
	t.Helper()
	return cleanProtectionNoReviews()
}

func cleanProtectionNoReviews() json.RawMessage {
	return json.RawMessage(`{
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
	}`)
}

type fakeGitHub struct {
	meta                domain.RepoMetadata
	metaErr             error
	protectionRaw       json.RawMessage
	protectionMissing   bool
	protectionErr       error
	topics              []string
	topicsErr           error
	updateProtectionErr error
	patchErr            error
	replaceTopicsErr    error

	updatedProtection string
	patchPayloads     [][]byte
	replacedTopics    []string
	branchSeen        string
}

func (f *fakeGitHub) RepoMetadata(context.Context, string) (domain.RepoMetadata, error) {
	return f.meta, f.metaErr
}

func (f *fakeGitHub) BranchProtection(_ context.Context, _ string, branch string) (json.RawMessage, bool, error) {
	f.branchSeen = branch
	return f.protectionRaw, f.protectionMissing, f.protectionErr
}

func (f *fakeGitHub) UpdateBranchProtection(_ context.Context, repo, branch string, payload []byte) error {
	f.updatedProtection = repo + "/branches/" + branch + "/protection " + string(payload)
	return f.updateProtectionErr
}

func (f *fakeGitHub) Topics(context.Context, string) ([]string, error) {
	return append([]string(nil), f.topics...), f.topicsErr
}

func (f *fakeGitHub) ReplaceTopics(_ context.Context, _ string, topics []string) error {
	f.replacedTopics = append([]string(nil), topics...)
	return f.replaceTopicsErr
}

func (f *fakeGitHub) PatchRepository(_ context.Context, _ string, payload []byte) error {
	f.patchPayloads = append(f.patchPayloads, append([]byte(nil), payload...))
	return f.patchErr
}

type fakeStore struct {
	defaults      domain.RepoDefaults
	readErr       error
	targetExists  bool
	targetErr     error
	lockExists    bool
	lockExistsErr error
	lockErr       error
	marker        string
}

func (f *fakeStore) ReadDefaults(string) (domain.RepoDefaults, error) {
	return f.defaults, f.readErr
}

func (f *fakeStore) TargetExists(string) (bool, error) {
	return f.targetExists, f.targetErr
}

func (f *fakeStore) LockExists(string) (bool, error) {
	return f.lockExists, f.lockExistsErr
}

func (f *fakeStore) UpdateLockDefaultsMarker(_ string, marker string) error {
	f.marker = marker
	return f.lockErr
}
