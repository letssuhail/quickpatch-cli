import 'package:quickpatch_code_push_protocol/quickpatch_code_push_protocol.dart';
import 'package:test/test.dart';

void main() {
  group(Patch, () {
    test('can be (de)serialized', () {
      const patch = Patch(id: 1, number: 2, notes: 'some notes');
      expect(Patch.fromJson(patch.toJson()).toJson(), equals(patch.toJson()));
      expect(Patch.fromJson(patch.toJson()), equals(patch));
    });
  });
}
