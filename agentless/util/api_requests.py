import time
import threading
import re
import os
from typing import Dict, Union, Optional

import anthropic
import openai
import tiktoken


def num_tokens_from_messages(message, model="gpt-5-mini-2025-08-07"):
    """Returns the number of tokens used by a list of messages."""
    try:
        encoding = tiktoken.encoding_for_model(model)
    except KeyError:
        encoding = tiktoken.get_encoding("cl100k_base")
    if isinstance(message, list):
        # use last message.
        num_tokens = len(encoding.encode(message[0]["content"]))
    else:
        num_tokens = len(encoding.encode(message))
    return num_tokens


def create_chatgpt_config(
    message: Union[str, list],
    max_tokens: int,
    temperature: float = 1,
    batch_size: int = 1,
    system_message: str = "You are a helpful assistant.",
    model: str = "gpt-5-mini-2025-08-07",
    reasoning_effort: str = "minimal"
) -> Dict:
    if isinstance(message, list):
        config = {
            "model": model,
            "max_completion_tokens": max_tokens,
            "n": batch_size,
            "reasoning_effort": reasoning_effort,
            "messages": [{"role": "system", "content": system_message}] + message,
        }
    else:
        config = {
            "model": model,
            "max_completion_tokens": max_tokens,
            "n": batch_size,
            "reasoning_effort": reasoning_effort,
            "messages": [
                {"role": "system", "content": system_message},
                {"role": "user", "content": message},
            ],
        }

    # Avoid adding model-specific reasoning fields to chat.completions request, as not all SDKs support them.
    return config


def handler(signum, frame):
    # swallow signum and frame
    raise Exception("end of time")


def request_chatgpt_engine(config, logger, base_url=None, max_retries=40, timeout=100):
    ret = None
    retries = 0

    client = openai.OpenAI(base_url=base_url)

    while ret is None and retries < max_retries:
        try:
            # Respect a minimal cooldown between OpenAI requests to avoid 429s
            _sleep_if_needed_for_openai_cooldown(logger)
            # Attempt to get the completion
            logger.info("Creating API request")

            ret = client.chat.completions.create(**config)

        except openai.OpenAIError as e:
            if isinstance(e, openai.BadRequestError):
                logger.info("Request invalid")
                print(e)
                logger.info(e)
                raise Exception("Invalid API Request")
            elif isinstance(e, openai.RateLimitError):
                print("Rate limit exceeded. Waiting...")
                logger.info("Rate limit exceeded. Waiting...")
                print(e)
                logger.info(e)
                # If the server suggests a wait time (e.g. "Please try again in 1.384s"), respect it
                retry_after = _extract_retry_after_seconds(e)
                if retry_after is None:
                    retry_after = 2.0  # sensible default backoff
                time.sleep(retry_after)
            elif isinstance(e, openai.APIConnectionError):
                print("API connection error. Waiting...")
                logger.info("API connection error. Waiting...")
                print(e)
                logger.info(e)
                time.sleep(5)
            else:
                print("Unknown error. Waiting...")
                logger.info("Unknown error. Waiting...")
                print(e)
                logger.info(e)
                time.sleep(1)

        retries += 1

    logger.info(f"API response {ret}")
    # Auto-retry once with a higher token budget if the model consumed all tokens for reasoning and returned empty content.
    try:
        if (
            ret
            and getattr(ret, "choices", None)
            and len(ret.choices) > 0
            and (ret.choices[0].message.content is None or ret.choices[0].message.content == "")
        ):
            # Check if we hit the token ceiling purely on reasoning tokens
            details = getattr(getattr(ret, "usage", None), "completion_tokens_details", None)
            reasoning_tokens = getattr(details, "reasoning_tokens", None)
            accepted_pred = getattr(details, "accepted_prediction_tokens", None)
            # Get the configured cap
            cap = config.get("max_tokens") or config.get("max_completion_tokens")
            if cap and reasoning_tokens and (accepted_pred in (0, None)):
                logger.info("Empty content likely due to reasoning tokens exhausting the budget; retrying with higher max tokens...")
                bumped = int(cap) + max(512, int(cap) // 2)
                # Update config with larger token limits and lower reasoning effort
                config["max_tokens"] = bumped
                config["max_completion_tokens"] = bumped
                _sleep_if_needed_for_openai_cooldown(logger)
                ret = client.chat.completions.create(**config)
                logger.info(f"API response (retry with bumped tokens) {ret}")
    except Exception:
        # Be conservative; any parsing error here should not break the flow.
        pass
    return ret


def create_anthropic_config(
    message: str,
    max_tokens: int,
    temperature: float = 1,
    batch_size: int = 1,
    system_message: str = "You are a helpful assistant.",
    model: str = "claude-2.1",
    tools: Optional[list] = None,
) -> Dict:
    if isinstance(message, list):
        config = {
            "model": model,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "messages": message,
        }
    else:
        config = {
            "model": model,
            "temperature": temperature,
            "max_tokens": max_tokens,
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": message}]},
            ],
        }

    if tools:
        config["tools"] = tools

    return config


def request_anthropic_engine(
    config, logger, max_retries=40, timeout=500, prompt_cache=False
):
    ret = None
    retries = 0

    client = anthropic.Anthropic()

    while ret is None and retries < max_retries:
        # ensure start_time is always defined for linter correctness
        start_time = time.time()
        try:
            if prompt_cache:
                # following best practice to cache mainly the reused content at the beginning
                # this includes any tools, system messages (which is already handled since we try to cache the first message)
                config["messages"][0]["content"][0]["cache_control"] = {
                    "type": "ephemeral"
                }
                # Access beta.prompt_caching via getattr to avoid attribute errors in older SDKs
                beta = getattr(client, "beta", None)
                prompt_caching = getattr(beta, "prompt_caching", None) if beta else None
                if prompt_caching and hasattr(prompt_caching, "messages"):
                    ret = prompt_caching.messages.create(**config)
                else:
                    # Fallback to regular messages.create if prompt caching is unavailable
                    ret = client.messages.create(**config)
            else:
                ret = client.messages.create(**config)
        except Exception as e:
            logger.error("Unknown error. Waiting...", exc_info=True)
            # Check if the timeout has been exceeded
            if time.time() - start_time >= timeout:
                logger.warning("Request timed out. Retrying...")
            else:
                logger.warning("Retrying after an unknown error...")
            time.sleep(10 * retries)
        retries += 1

    return ret


# --- Simple, process-wide OpenAI cooldown (thread-safe) ---
# Allow overriding via env var OPENAI_MIN_COOLDOWN_SEC (seconds)
try:
    _OPENAI_COOLDOWN_SEC = float(os.getenv("OPENAI_MIN_COOLDOWN_SEC", "1.0"))
except Exception:
    _OPENAI_COOLDOWN_SEC = 1.0
_last_openai_request_ts = 0.0
_openai_ts_lock = threading.Lock()


def _sleep_if_needed_for_openai_cooldown(logger=None):
    """Ensure at least _OPENAI_COOLDOWN_SEC between OpenAI requests.

    This provides a coarse-grained throttle to avoid spiky 429s.
    It spaces the start-time of requests by the configured cooldown.
    """
    global _last_openai_request_ts
    with _openai_ts_lock:
        now = time.time()
        wait = _OPENAI_COOLDOWN_SEC - (now - _last_openai_request_ts)
        if wait > 0:
            if logger:
                try:
                    logger.info(f"Respecting OpenAI cooldown: sleeping {wait:.2f}s")
                except Exception:
                    pass
            time.sleep(wait)
        # mark the start time of this request
        _last_openai_request_ts = time.time()


def _extract_retry_after_seconds(e: Exception):
    """Try to extract server-suggested retry-after seconds from an OpenAI error.

    Looks for patterns like "Please try again in 1.384s" in the message,
    and also checks a 'retry-after' header if available on the response.
    Returns a float seconds value or None.
    """
    # Try response headers if present
    try:
        resp = getattr(e, "response", None)
        if resp is not None:
            headers = getattr(resp, "headers", None)
            if headers:
                retry_after = headers.get("retry-after") or headers.get("Retry-After")
                if retry_after:
                    try:
                        return float(retry_after)
                    except ValueError:
                        # Some servers may return a date; ignore in that case
                        pass
    except Exception:
        pass

    # Fallback: parse from the stringified message
    try:
        msg = str(e)
        m = re.search(r"try again in ([0-9]*\.?[0-9]+)s", msg, re.IGNORECASE)
        if m:
            return float(m.group(1))
    except Exception:
        pass

    return None
