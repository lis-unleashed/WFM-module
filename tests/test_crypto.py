import pytest

from app.core.crypto import TokenCipher, TokenDecryptionError, generate_key, parse_keys


def test_tokens_round_trip_and_are_not_stored_in_the_clear():
    cipher = TokenCipher(generate_key())
    stored = cipher.encrypt("refresh-token-123")
    assert b"refresh-token-123" not in stored
    assert cipher.encrypt("refresh-token-123") != stored  # a fresh IV every time
    assert cipher.decrypt(stored) == "refresh-token-123"


def test_a_key_can_be_rotated_without_losing_saved_tokens():
    old, new = generate_key(), generate_key()
    stored = TokenCipher(old).encrypt("refresh-token")

    during_rotation = TokenCipher(f"{new},{old}")
    assert during_rotation.decrypt(stored) == "refresh-token"
    rotated = during_rotation.rotate(stored)

    after_rotation = TokenCipher(new)  # the old key has been retired
    assert after_rotation.decrypt(rotated) == "refresh-token"
    with pytest.raises(TokenDecryptionError):
        after_rotation.decrypt(stored)


def test_new_tokens_use_the_newest_key():
    old, new = generate_key(), generate_key()
    stored = TokenCipher(f"{new},{old}").encrypt("refresh-token")
    assert TokenCipher(new).decrypt(stored) == "refresh-token"


def test_the_wrong_key_cannot_decrypt():
    stored = TokenCipher(generate_key()).encrypt("refresh-token")
    with pytest.raises(TokenDecryptionError):
        TokenCipher(generate_key()).decrypt(stored)


@pytest.mark.parametrize("keys", ["", " , ", "not-a-key", "c2hvcnQ="])
def test_bad_keys_are_refused(keys):
    with pytest.raises(ValueError, match="key"):
        parse_keys(keys)
