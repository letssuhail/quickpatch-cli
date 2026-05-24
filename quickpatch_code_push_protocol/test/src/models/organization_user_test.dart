import 'package:quickpatch_code_push_protocol/quickpatch_code_push_protocol.dart';
import 'package:test/test.dart';

void main() {
  group(OrganizationUser, () {
    test('can be (de)serialized', () {
      final organizationUser = OrganizationUser(
        user: publicUserFromPrivateUser(privateUserForTest()),
        role: Role.developer,
      );
      expect(
        OrganizationUser.fromJson(organizationUser.toJson()).toJson(),
        equals(organizationUser.toJson()),
      );
    });
  });
}
