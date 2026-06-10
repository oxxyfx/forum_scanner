class ForumSource {
  final String id;
  final String name;
  final String baseUrl;
  final String username;
  final String password;
  final int colorValue;

  ForumSource({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.colorValue,
  });

  // Convert a ForumSource object into a JSON-friendly Map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'username': username,
      'password': password,
      'colorValue': colorValue,
    };
  }

  // Create a ForumSource object from a JSON-friendly Map
  factory ForumSource.fromJson(Map<String, dynamic> json) {
    return ForumSource(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      baseUrl: json['baseUrl'] ?? '',
      username: json['username'] ?? '',
      password: json['password'] ?? '',
      colorValue: json['colorValue'] ?? 0xFF42A5F5,
    );
  }
}