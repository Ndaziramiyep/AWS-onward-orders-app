"""Onward Logistics order system: one container serving the UI and the order logic."""

import json
import os
import socket
import time
import urllib.request
from datetime import datetime, timezone
from itertools import count

from flask import Flask, jsonify, render_template, request

import settings

app = Flask(__name__)

# Git SHA baked into the image at build time, so every page shows which release served it.
APP_VERSION = os.getenv("APP_VERSION", "dev")

# Demo orders live in memory, per task. Order numbers start at 1001.
_order_ids = count(1001)
ORDERS = []


def task_location():
    """Return (task id, availability zone) from ECS task metadata, or local values off ECS."""
    uri = os.getenv("ECS_CONTAINER_METADATA_URI_V4")  # Set by Fargate inside every task
    if not uri:
        return socket.gethostname(), "local"
    try:
        # The metadata endpoint is link-local, so it works without any internet path.
        with urllib.request.urlopen(f"{uri}/task", timeout=1) as resp:
            meta = json.load(resp)
        task_id = meta.get("TaskARN", "").rsplit("/", 1)[-1][:12]
        return task_id, meta.get("AvailabilityZone", "unknown")
    except Exception:
        # Never let a metadata problem break the page.
        return socket.gethostname(), "unknown"


TASK_ID, AZ = task_location()


@app.get("/")
def index():
    """Home page: full name, lab name, release version and the task/AZ that answered."""
    return render_template(
        "index.html",
        student=settings.STUDENT_NAME,
        lab=settings.LAB_NAME,
        version=APP_VERSION,
        note=settings.RELEASE_NOTE,
        task_id=TASK_ID,
        az=AZ,
        orders=list(reversed(ORDERS[-10:])),
    )


@app.post("/orders")
def create_order():
    """Create a demo order from an HTML form post or a JSON body."""
    data = request.get_json(silent=True) or request.form
    item = (data.get("item") or "").strip()[:60]
    try:
        qty = int(data.get("quantity") or 1)
    except (TypeError, ValueError):
        qty = 0  # Not a number: rejected below as a 400, never a 500 (5XX errors trigger a rollback)
    if not item or not 1 <= qty <= 1000:
        return jsonify(error="item required, quantity 1-1000"), 400

    order = {
        "id": next(_order_ids),
        "item": item,
        "quantity": qty,
        "created": datetime.now(timezone.utc).strftime("%H:%M:%S UTC"),
        "task": TASK_ID,
    }
    ORDERS.append(order)
    if request.is_json:
        return jsonify(order), 201
    return index()


@app.get("/health")
def health():
    """Health check for the ALB and the container. Returns 500 only for the bad-release demo."""
    if settings.FORCE_UNHEALTHY:
        return "unhealthy", 500
    return "ok", 200


@app.get("/version")
def version():
    """Machine-readable version, used by the zero-downtime curl loop."""
    return jsonify(version=APP_VERSION, task=TASK_ID, az=AZ)


@app.get("/cpu")
def burn_cpu():
    """Burn CPU for N seconds (max 10) to demonstrate auto scaling."""
    try:
        seconds = min(float(request.args.get("seconds", 2)), 10.0)
    except ValueError:
        return jsonify(error="seconds must be a number"), 400
    end = time.time() + seconds
    n = 0
    while time.time() < end:
        n += 1
    return jsonify(burned_seconds=seconds, iterations=n, task=TASK_ID)


if __name__ == "__main__":
    # Local run without gunicorn, on the same port as the container.
    app.run(host="0.0.0.0", port=8080)
