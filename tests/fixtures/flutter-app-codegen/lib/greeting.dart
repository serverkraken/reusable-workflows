import 'package:json_annotation/json_annotation.dart';

// `part` verweist auf eine Datei, die es im Repo NICHT gibt: greeting.g.dart
// entsteht erst durch `dart run build_runner build`. Ohne diesen Schritt
// scheitert `flutter analyze` an der fehlenden Teil-Datei und an den beiden
// nicht existierenden Funktionen unten.
//
// Genau das ist der Zweck dieser Fixture (Audit K-10): `use_build_runner`
// steht in allen vier Flutter-Atomen auf `true`, und JEDER Aufrufer im Katalog
// uebergab `false`. Der Vorgabepfad — der, den Adopter bekommen — lief nie.
//
// Hier ist ein gruener Lauf die Zusicherung, und das ist keine schwache Form
// davon: ohne die erzeugte Datei KANN analyze nicht bestehen. Die Gegenprobe
// in failure-paths-nightly.yml faehrt dieselbe Fixture mit
// `use_build_runner: false` und verlangt, dass sie scheitert — sonst koennte
// dieser Test leer bestehen.
part 'greeting.g.dart';

@JsonSerializable()
class Greeting {
  const Greeting({required this.message, required this.count});

  factory Greeting.fromJson(Map<String, dynamic> json) =>
      _$GreetingFromJson(json);

  final String message;
  final int count;

  Map<String, dynamic> toJson() => _$GreetingToJson(this);
}
