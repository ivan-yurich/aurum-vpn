enum ConnectionStatus {
  connected('Подключено'),
  disconnected('Отключено'),
  connecting('Подключение...');

  const ConnectionStatus(this.displayName);

  final String displayName;
}
