"""Bounded, non-executable JSON messages on private parent/worker pipes."""
import base64
import json
import struct

MAX_MESSAGE_BYTES = 32 * 1024 * 1024


def encode_message(value):
    body = json.dumps(value, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(body) > MAX_MESSAGE_BYTES:
        raise ValueError("worker-message-limit")
    return struct.pack("!I", len(body)) + body


def read_message(stream):
    prefix = stream.read(4)
    if not prefix:
        return None
    if len(prefix) != 4:
        raise ValueError("worker-message-truncated")
    length = struct.unpack("!I", prefix)[0]
    if length < 2 or length > MAX_MESSAGE_BYTES:
        raise ValueError("worker-message-limit")
    body = stream.read(length)
    if len(body) != length:
        raise ValueError("worker-message-truncated")
    return json.loads(body)


async def read_async_message(stream):
    prefix = await stream.readexactly(4)
    length = struct.unpack("!I", prefix)[0]
    if length < 2 or length > MAX_MESSAGE_BYTES:
        raise ValueError("worker-message-limit")
    return json.loads(await stream.readexactly(length))


def encode_outcome(outcome):
    return {
        "content_hash": outcome.content_hash,
        "response": outcome.response,
        "decision": outcome.decision.to_dict(),
        "cache_hit": outcome.cache_hit,
        "replacement": (base64.b64encode(outcome.replacement_bytes).decode("ascii")
                        if outcome.replacement_bytes is not None else None),
        "replacement_mime_type": outcome.replacement_mime_type,
    }


def decode_outcome(value):
    from local_image_filter.domain.models import FilterAction, FilterDecision, FilterOutcome
    decision = value["decision"]
    return FilterOutcome(
        content_hash=value["content_hash"], response=value["response"],
        decision=FilterDecision(
            action=FilterAction(decision["action"]), reasons=tuple(decision["reasons"]),
            evidence_ids=tuple(decision.get("evidenceIds", [])),
            model_evidence_complete=bool(decision["modelEvidenceComplete"]),
        ),
        cache_hit=bool(value["cache_hit"]),
        replacement_bytes=(base64.b64decode(value["replacement"], validate=True)
                           if value["replacement"] is not None else None),
        replacement_mime_type=value["replacement_mime_type"],
    )
