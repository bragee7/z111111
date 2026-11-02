import 'package:flutter/foundation.dart';

import '../models/emergency_contact.dart';
import '../services/contacts_service.dart';

class ContactsProvider extends ChangeNotifier {
  final ContactsService _contactsService = ContactsService();

  List<EmergencyContact> _contacts = [];
  bool _loading = false;
  String _error = '';

  List<EmergencyContact> get contacts => _contacts;
  bool get isLoading => _loading;
  String get error => _error;

  void dismissError() {
    _error = '';
    notifyListeners();
  }

  Future<void> fetchContacts() async {
    _loading = true;
    _error = '';
    notifyListeners();
    try {
      _contacts = await _contactsService.getContacts();
    } catch (e) {
      _contacts = [];
      _error = 'Could not load contacts: $e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> add({
    required String name,
    required String phone,
    String email = '',
    String relation = '',
    int priority = 1,
  }) async {
    await _contactsService.addContact(
      name: name,
      phone: phone,
      email: email,
      relation: relation,
      priority: priority,
    );
    await fetchContacts();
  }

  Future<void> update(
    String id, {
    required String name,
    required String phone,
    String email = '',
    String relation = '',
    int priority = 1,
  }) async {
    await _contactsService.updateContact(
      id,
      name: name,
      phone: phone,
      email: email,
      relation: relation,
      priority: priority,
    );
    await fetchContacts();
  }

  Future<void> remove(String id) async {
    await _contactsService.deleteContact(id);
    await fetchContacts();
  }
}
