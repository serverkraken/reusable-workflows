package ports

import (
	"context"
	"reflect"
	"testing"
)

func TestStaticGitHubMetadataDefaultsAndValues(t *testing.T) {
	zero := StaticGitHubMetadata{}
	if b, _ := zero.DefaultBranch(context.Background(), "x/y"); b != "main" {
		t.Fatalf("branch=%s", b)
	}
	if v, _ := zero.LatestStableRelease(context.Background(), "x/y"); v != "0.0.0" {
		t.Fatalf("version=%s", v)
	}
	if topics, _ := zero.Topics(context.Background(), "x/y"); len(topics) != 0 {
		t.Fatalf("topics=%v", topics)
	}

	meta := StaticGitHubMetadata{Branch: "trunk", Version: "1.2.3", Names: []string{"a"}}
	if b, _ := meta.DefaultBranch(context.Background(), "x/y"); b != "trunk" {
		t.Fatalf("branch=%s", b)
	}
	if v, _ := meta.LatestStableRelease(context.Background(), "x/y"); v != "1.2.3" {
		t.Fatalf("version=%s", v)
	}
	topics, _ := meta.Topics(context.Background(), "x/y")
	topics[0] = "mutated"
	again, _ := meta.Topics(context.Background(), "x/y")
	if !reflect.DeepEqual(again, []string{"a"}) {
		t.Fatalf("topics not copied: %v", again)
	}
}
