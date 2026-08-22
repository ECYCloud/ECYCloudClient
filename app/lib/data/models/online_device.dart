class OnlineDevice {
  const OnlineDevice({
    required this.ip,
    required this.device,
    required this.location,
    required this.datetime,
  });

  final String ip;
  final String device;
  final String location;
  final String datetime;

  factory OnlineDevice.fromJson(Map<String, dynamic> json) => OnlineDevice(
    ip: json['ip'] as String? ?? '',
    device: json['device'] as String? ?? '',
    location: json['location'] as String? ?? '',
    datetime: json['datetime'] as String? ?? '',
  );
}
