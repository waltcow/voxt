#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request


DEFAULT_MODELS = [
    "mlx-community/Qwen3-ASR-0.6B-4bit",
    "mlx-community/Qwen3-ASR-1.7B-4bit",
    "mlx-community/parakeet-tdt-0.6b-v3",
    "mlx-community/GLM-ASR-Nano-2512-4bit",
]


def request(url: str, timeout: float, user_agent: str, headers: dict | None = None) -> tuple[int, dict, bytes]:
    req = urllib.request.Request(url)
    req.add_header("User-Agent", user_agent)
    if headers:
        for key, value in headers.items():
            req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.status, dict(response.headers.items()), response.read()


def check_model(base_url: str, repo: str, timeout: float, user_agent: str) -> tuple[bool, list[str]]:
    errors: list[str] = []
    encoded_repo = urllib.parse.quote(repo, safe="/")

    info_url = f"{base_url}/api/models/{encoded_repo}"
    tree_url = f"{base_url}/api/models/{encoded_repo}/tree/main?recursive=1"

    try:
        status, _, body = request(info_url, timeout=timeout, user_agent=user_agent)
        if status < 200 or status >= 300:
            errors.append(f"model info http {status}")
        else:
            model_info = json.loads(body)
            if model_info.get("id") != repo:
                errors.append(f"model info id mismatch: {model_info.get('id')!r}")
    except Exception as exc:
        errors.append(f"model info failed: {exc}")
        return False, errors

    try:
        status, _, body = request(tree_url, timeout=timeout, user_agent=user_agent)
        if status < 200 or status >= 300:
            errors.append(f"tree http {status}")
            return False, errors
        tree = json.loads(body)
    except Exception as exc:
        errors.append(f"tree failed: {exc}")
        return False, errors

    files = [item for item in tree if item.get("type") == "file"]
    if not files:
        errors.append("tree has no files")
        return False, errors

    config_paths = [item.get("path", "") for item in files if str(item.get("path", "")).lower().endswith("config.json")]
    safetensor_paths = [item.get("path", "") for item in files if str(item.get("path", "")).lower().endswith(".safetensors")]

    if not config_paths:
        errors.append("missing config.json in tree")
    if not safetensor_paths:
        errors.append("missing .safetensors in tree")
    if errors:
        return False, errors

    config_url = f"{base_url}/{repo}/resolve/main/{config_paths[0]}"
    try:
        status, _, body = request(config_url, timeout=timeout, user_agent=user_agent)
        if status < 200 or status >= 300:
            errors.append(f"config resolve http {status}")
        else:
            json.loads(body)
    except Exception as exc:
        errors.append(f"config resolve failed: {exc}")

    weights_url = f"{base_url}/{repo}/resolve/main/{safetensor_paths[0]}"
    try:
        status, headers, body = request(
            weights_url,
            timeout=timeout,
            user_agent=user_agent,
            headers={"Range": "bytes=0-255"},
        )
        if status not in (200, 206):
            errors.append(f"safetensors resolve http {status}")
        content_length = headers.get("Content-Length")
        if content_length is not None:
            try:
                if int(content_length) <= 0:
                    errors.append("safetensors content-length <= 0")
            except ValueError:
                errors.append(f"safetensors invalid content-length: {content_length!r}")
        if not body:
            errors.append("safetensors body empty")
    except Exception as exc:
        errors.append(f"safetensors resolve failed: {exc}")

    return len(errors) == 0, errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Smoke check MLX model availability on HF mirror.")
    parser.add_argument("--base-url", default="https://hf-mirror.com", help="Hub base url")
    parser.add_argument(
        "--model",
        action="append",
        dest="models",
        help="Model repo id (can pass multiple times). Defaults to built-in models.",
    )
    parser.add_argument("--timeout", type=float, default=20.0, help="Request timeout seconds")
    parser.add_argument("--user-agent", default="Voxt/1.0 (MLXAudio)", help="User-Agent header value")
    args = parser.parse_args()

    base_url = args.base_url.rstrip("/")
    models = args.models or DEFAULT_MODELS

    print(f"Base URL: {base_url}")
    print(f"Models: {len(models)}")
    print("")

    failures = 0
    for repo in models:
        ok, errors = check_model(base_url=base_url, repo=repo, timeout=args.timeout, user_agent=args.user_agent)
        if ok:
            print(f"[PASS] {repo}")
            continue

        failures += 1
        print(f"[FAIL] {repo}")
        for item in errors:
            print(f"  - {item}")

    print("")
    if failures:
        print(f"Result: {failures}/{len(models)} failed")
        return 1
    print("Result: all checks passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except urllib.error.URLError as exc:
        print(f"Network error: {exc}", file=sys.stderr)
        raise SystemExit(2)
