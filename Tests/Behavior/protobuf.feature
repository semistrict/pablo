Feature: Store and exchange Pablo evidence with schema-defined protobuf
  Recordings use streaming protobuf journals and reject unsupported manifest versions.

  @automated
  # ProtobufStreamTests.protobufStreamRoundTrip
  Scenario: Multiple protobuf records retain exact boundaries and optional presence
    Given two input records contain different optional fields
    When Pablo appends both as unsigned-varint length-delimited protobuf messages
    Then the stream contains exactly two records
    And decoding preserves their order, timestamps, values, and absent fields

  @automated
  # ProtobufStreamTests.invalidProtobufFramingFailsClosed
  Scenario: Damaged protobuf framing fails closed
    Given a protobuf journal ends inside a record or has an invalid length prefix
    When Pablo reads the journal
    Then decoding fails
    And no partial record is presented as valid evidence

  @automated
  # ReplayRecordingTests.unsupportedRecordingVersionsAreRejected
  Scenario: Unsupported recording versions fail before journals are read
    Given a recording manifest declares a schema version other than three
    When Pablo opens the recording
    Then loading fails with an unsupported-format error
    And no journal is read or changed

  @automated
  # ProtobufStreamTests.controlBridgeUsesProtobufV3
  Scenario: The CLI and app exchange protobuf RPC envelopes
    Given the CLI creates a PabloControlService Call request
    When it serializes control protocol version three
    Then the request is protobuf rather than JSON
    And its request ID and method survive decoding
