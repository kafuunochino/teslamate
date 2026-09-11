"""Keep the vehicle timestamp in each retained MQTT reading.

The official MQTT dispatcher normally sends only the field value. After a
restart that would make an old retained value indistinguishable from a new
sample. This small, pinned-source adaptation wraps each field and leaves the
official TLS, vehicle authentication, protobuf decoding and ACK logic intact.
"""
from pathlib import Path

path = Path("datastore/mqtt/mqtt_payload.go")
source = path.read_text()
old = "\t\tjsonValue, err := json.Marshal(value)"
new = """\t\tjsonValue, err := json.Marshal(map[string]interface{}{
            "value": value,
            "created_at": payload.GetCreatedAt().AsTime().Format(time.RFC3339Nano),
        })"""
assert source.count(old) == 1, "Upstream MQTT implementation changed; review before updating"
path.write_text(source.replace(old, new))

# Exercise the retained envelope through the upstream MQTT producer tests.
tests = Path("datastore/mqtt/mqtt_test.go")
source = tests.read_text()
anchor = '\t\t\tbatterLevelValue := "75.5"'
helper = anchor + """
            envelope := func(raw string) []byte {
                var value interface{}
                Expect(json.Unmarshal([]byte(raw), &value)).To(Succeed())
                body, err := json.Marshal(map[string]interface{}{
                    "value": value,
                    "created_at": payload.GetCreatedAt().AsTime().Format(time.RFC3339Nano),
                })
                Expect(err).NotTo(HaveOccurred())
                return body
            }
"""
assert source.count(anchor) == 1
source = source.replace(anchor, helper)
for value in ["vehicleNameValue", "invalidValue", "locationValue", "batterLevelValue"]:
    old = "Equal([]byte(" + value + "))"
    assert source.count(old) == 1
    source = source.replace(old, "Equal(envelope(" + value + "))")
tests.write_text(source)
