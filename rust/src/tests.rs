use super::*;

struct Handle(*mut Session);
impl Handle {
    fn new() -> Self {
        let handle = dtb_create();
        assert!(!handle.is_null());
        Self(handle)
    }
    fn request(&self, input: &str) -> Json {
        let input = CString::new(input).unwrap();
        // This test owns the session and all request/response allocations.
        unsafe {
            let response = dtb_request(self.0, input.as_ptr());
            let result = serde_json::from_str(CStr::from_ptr(response).to_str().unwrap()).unwrap();
            dtb_free(response);
            result
        }
    }
}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { dtb_destroy(self.0) };
    }
}

#[test]
fn malformed_requests_are_errors_not_panics() {
    let session = Handle::new();
    assert!(session.request("not JSON")["error"].is_string());
    assert!(session.request(r#"{"op":"unknown"}"#)["error"].is_string());
    assert!(session.request(r#"{"op":"pull"}"#)["error"].is_string());
    assert!(session.request(r#"{"op":"open","path":":memory:"}"#)["result"].is_null());
    let result = session.request(r#"{"op":"query","statement":{"sql":"SELECT 42"}}"#);
    assert_eq!(result["result"]["rows"][0][0]["value"], "42");
}

#[test]
fn integer_wire_encoding_preserves_bounds_and_rejects_overflow() {
    for value in [i64::MIN, i64::MAX] {
        let encoded = serde_json::to_string(&Cell::Integer(value.to_string())).unwrap();
        let decoded: Cell = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded.into_value().unwrap(), turso::Value::Integer(value));
    }
    assert!(
        Cell::Integer("9223372036854775808".into())
            .into_value()
            .is_err()
    );
}

#[test]
fn embedded_nuls_and_blob_bytes_survive_wire_encoding() {
    for value in [
        turso::Value::Text("a\0b".into()),
        turso::Value::Blob(vec![0, 255]),
    ] {
        let cell = Cell::from_value(value.clone()).unwrap();
        let wire = serde_json::to_string(&cell).unwrap();
        assert!(!wire.as_bytes().contains(&0));
        let decoded: Cell = serde_json::from_str(&wire).unwrap();
        assert_eq!(decoded.into_value().unwrap(), value);
    }
}
