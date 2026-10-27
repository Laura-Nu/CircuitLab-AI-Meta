def test_pairing_attempt_budget(client, headers):
    for _ in range(5):
        response = client.post("/api/v1/pairing/redeem", headers=headers, json={"code": "invalid"})
        assert response.status_code == 422
    assert client.post("/api/v1/pairing/redeem", headers=headers, json={"code": "invalid"}).status_code == 429
