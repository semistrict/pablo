function pabloNativeCommandMessage(message, expectedName) {
  if (!message || typeof message !== "object") return undefined;
  const nested = [message, message.userInfo, message.message]
    .filter((value) => value && typeof value === "object");
  const names = nested
    .map((value) => value.name ?? value.messageName)
    .filter((value) => typeof value === "string");
  if (names.length && !names.includes(expectedName)) return undefined;
  return nested
    .map((value) => value.command)
    .find((value) => typeof value === "string");
}

globalThis.pabloNativeCommandMessage = pabloNativeCommandMessage;

if (typeof module !== "undefined") {
  module.exports = pabloNativeCommandMessage;
}
