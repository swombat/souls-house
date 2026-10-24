source ~/state/tools/env.sh
export GOROOT=/home/agent/state/tools/go
export GOPATH=/home/agent/state/tools/gopath
export GOMODCACHE=$GOPATH/pkg/mod
export GOCACHE=$GOPATH/cache
export GOTMPDIR=/home/agent/state/tools/gopath/tmp
export PATH=$GOROOT/bin:$GOPATH/bin:$PATH
export CGO_ENABLED=1
