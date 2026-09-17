import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/customer.dart';
import '../../state/customers.dart';
import '../../widgets/ui.dart';

/// Add / edit customer dialog.
class CustomerEditDialog extends StatefulWidget {
  final Customer? customer;
  const CustomerEditDialog({super.key, this.customer});

  @override
  State<CustomerEditDialog> createState() => _CustomerEditDialogState();
}

class _CustomerEditDialogState extends State<CustomerEditDialog> {
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _notes;

  bool get _isNew => widget.customer == null;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.customer?.name ?? '');
    _phone = TextEditingController(text: widget.customer?.phone ?? '');
    _email = TextEditingController(text: widget.customer?.email ?? '');
    _notes = TextEditingController(text: widget.customer?.notes ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name is required')));
      return;
    }
    final provider = context.read<CustomersProvider>();
    final existing = widget.customer ?? Customer(
      name: '',
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    await provider.save(existing.copyWith(
      name: _name.text.trim(),
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      email: _email.text.trim().isEmpty ? null : _email.text.trim(),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    ));
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      title: Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppColors.primarySoft,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            _isNew ? Icons.person_add_alt_rounded : Icons.edit_outlined,
            size: 19,
            color: AppColors.primary,
          ),
        ),
        const SizedBox(width: 11),
        Text(_isNew ? 'New customer' : 'Edit customer'),
      ]),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: _isNew,
              decoration: const InputDecoration(
                  labelText: 'Name *',
                  prefixIcon: Icon(Icons.person_outline_rounded, size: 20)),
            ),
            const SizedBox(height: 13),
            TextField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                  labelText: 'Phone',
                  prefixIcon: Icon(Icons.phone_outlined, size: 20)),
            ),
            const SizedBox(height: 13),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.alternate_email_rounded, size: 20)),
            ),
            const SizedBox(height: 13),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(
                  labelText: 'Notes',
                  prefixIcon: Icon(Icons.notes_rounded, size: 20)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
