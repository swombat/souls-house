"""Synthetic-only whole-clip resource probe; never reads audio or credentials.

Run in the same environment as server.py:
  python benchmark.py --model-dir /model
Use an external cgroup/container for enforcement; ru_maxrss is process RSS only.
"""
import argparse
import json
import resource
import time

import server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", required=True)
    args = parser.parse_args()
    server.profile()
    server.torch.set_num_threads(2)
    server.torch.set_num_interop_threads(1)
    model = server.load_model(args.model_dir)
    rng = server.np.random.default_rng(0)
    for seconds in (2, 30, 60, 120):
        samples = rng.normal(0, 0.1, seconds * server.SAMPLE_RATE).astype("float32")
        start = time.monotonic()
        cpu = time.process_time()
        vector = server.embed(model, samples)
        print(json.dumps({
            "seconds": seconds, "elapsed_seconds": time.monotonic() - start,
            "cpu_seconds": time.process_time() - cpu,
            "peak_rss_kib": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "dimensions": len(vector), "norm": float(server.np.linalg.norm(vector)),
        }), flush=True)


if __name__ == "__main__":
    main()
