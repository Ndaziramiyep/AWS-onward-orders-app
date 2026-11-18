"""Unit tests run by GitHub Actions before any image is built."""

import sys
from pathlib import Path

# Make app/ importable, the same way the container runs it.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))

import main  # noqa: E402
import settings  # noqa: E402

client = main.app.test_client()


def test_home_shows_name_and_lab():
    """The page must show the full name and the lab name (lab requirement)."""
    body = client.get("/").get_data(as_text=True)
    assert settings.STUDENT_NAME in body
    assert settings.LAB_NAME in body


def test_health_matches_release_switch():
    """/health is 200 normally and 500 only when the bad-release demo switch is on."""
    expected = 500 if settings.FORCE_UNHEALTHY else 200
    assert client.get("/health").status_code == expected


def test_create_order_json():
    """The orders API accepts JSON and returns 201."""
    resp = client.post("/orders", json={"item": "Pallet", "quantity": 3})
    assert resp.status_code == 201
    assert resp.get_json()["item"] == "Pallet"


def test_create_order_form():
    """The HTML form returns the page with the new order on it."""
    resp = client.post("/orders", data={"item": "Crate", "quantity": "2"})
    assert resp.status_code == 200
    assert "Crate" in resp.get_data(as_text=True)


def test_invalid_orders_are_400_not_500():
    """Bad input is the caller's error (400). A 500 would trip the 5XX alarm and roll back a release."""
    assert client.post("/orders", json={"item": ""}).status_code == 400
    assert client.post("/orders", json={"item": "Box", "quantity": "abc"}).status_code == 400
    assert client.post("/orders", json={"item": "Box", "quantity": 5000}).status_code == 400
    assert client.get("/cpu?seconds=abc").status_code == 400


def test_version_endpoint():
    """/version reports the build version."""
    assert "version" in client.get("/version").get_json()
