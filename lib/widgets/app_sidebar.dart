import 'package:flutter/material.dart';

import '../models/user.dart';
import 'ui.dart';

/// One destination in the [AppSidebar].
class SidebarDest {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const SidebarDest({required this.icon, required this.activeIcon, required this.label});
}

/// Desktop navigation sidebar — the M3 navigation-drawer pattern styled
/// with the app design tokens (AppColors / AppRadius / AppSpace / Carlito).
///
/// * **Extended** (window >= 1240dp): 244dp — brand header, labeled pill
///   items, manager section, user card with an account menu.
/// * **Collapsed** (900–1240dp): 72dp icon rail with tooltips; the account
///   menu stays reachable from the avatar.
///
/// Replaces the stock NavigationRail, which rendered as default Flutter
/// chrome (labels under icons, no brand, no hover styling) instead of the
/// app's design language.
class AppSidebar extends StatefulWidget {
  final bool extended;
  final List<SidebarDest> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final AppUser user;

  /// Manager-only actions; null hides the whole MANAGE section entry.
  final VoidCallback? onSettings;
  final VoidCallback? onStaff;
  final VoidCallback onChangePassword;
  final VoidCallback onSignOut;

  const AppSidebar({
    super.key,
    required this.extended,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelect,
    required this.user,
    required this.onChangePassword,
    required this.onSignOut,
    this.onSettings,
    this.onStaff,
  });

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> {
  int _hover = -1;

  bool get _extended => widget.extended;

  // ------------------------------------------------------------------
  // Building blocks
  // ------------------------------------------------------------------

  Widget _brandTile() => Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: AppColors.brandGradient,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: const Icon(Icons.storefront_rounded, size: 21, color: Colors.white),
      );

  Widget _brandHeader() {
    final tile = _brandTile();
    if (!_extended) {
      return Padding(
        padding: const EdgeInsets.only(top: AppSpace.s5, bottom: AppSpace.s1),
        child: Center(child: Tooltip(message: 'StylePOS', child: tile)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s5, AppSpace.s4, AppSpace.s1),
      child: Row(
        children: [
          tile,
          const SizedBox(width: AppSpace.s3),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('StylePOS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 16,
                        height: 22 / 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.ink)),
                SizedBox(height: 2),
                Text('Point of sale',
                    maxLines: 1,
                    style: TextStyle(
                        fontFamily: 'Carlito', fontSize: 11.5, height: 16 / 11.5, color: AppColors.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(AppSpace.s5, AppSpace.s5, AppSpace.s4, AppSpace.s2),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontFamily: 'Carlito',
                fontSize: 11,
                height: 16 / 11,
                letterSpacing: 0.4,
                fontWeight: FontWeight.w700,
                color: AppColors.faint)),
      );

  /// One navigation row — pill highlight, 44dp target, hover state.
  /// In collapsed mode renders as a centered icon square with a tooltip.
  Widget _navRow({
    required IconData icon,
    required IconData activeIcon,
    required String label,
    required VoidCallback onTap,
    required bool selected,
    String? tooltip,
  }) {
    final fg = selected ? AppColors.primaryDark : AppColors.muted;
    final hovered = _hover == label.hashCode && !selected;

    final square = AnimatedContainer(
      duration: AppMotion.normal,
      curve: AppMotion.standard,
      height: 44,
      padding: _extended
          ? const EdgeInsets.symmetric(horizontal: AppSpace.s4)
          : EdgeInsets.zero,
      // Collapsed rows are 48dp squares inside the 72dp rail.
      width: _extended ? null : 48,
      decoration: BoxDecoration(
        color: selected
            ? AppColors.primarySoft
            : hovered
                ? AppColors.surfaceTint
                : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      alignment: Alignment.center,
      child: _extended
          ? Row(
              children: [
                Icon(selected ? activeIcon : icon, size: 21, color: fg),
                const SizedBox(width: AppSpace.s3),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: 'Carlito',
                        fontSize: 14,
                        letterSpacing: 0.1,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                        color: fg),
                  ),
                ),
              ],
            )
          : Icon(selected ? activeIcon : icon, size: 22, color: fg),
    );

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.s3),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.transparent, // hover handled by AnimatedContainer
          splashColor: AppColors.primary.withValues(alpha: 0.06),
          highlightColor: Colors.transparent,
          onHover: (v) => setState(() => _hover = v ? label.hashCode : -1),
          child: square,
        ),
      ),
    );

    if (tooltip != null && !_extended) {
      row = Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 400), child: row);
    }
    return row;
  }

  // ------------------------------------------------------------------
  // Footer — user card + account menu
  // ------------------------------------------------------------------

  Widget _footer() {
    final u = widget.user;
    final roleColor = u.isAdmin ? AppColors.primaryDark : AppColors.info;
    final roleSoft = u.isAdmin ? AppColors.primarySoft : AppColors.infoSoft;

    final card = _extended
        ? Container(
            margin: const EdgeInsets.symmetric(horizontal: AppSpace.s3),
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.s2 + 2, vertical: AppSpace.s2),
            decoration: BoxDecoration(
              color: AppColors.surfaceTint,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: AppColors.borderSoft),
            ),
            child: Row(
              children: [
                InitialsAvatar(u.name, size: 32),
                const SizedBox(width: AppSpace.s2 + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(u.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontFamily: 'Carlito',
                              fontSize: 13,
                              height: 18 / 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.ink)),
                      const SizedBox(height: 1),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpace.s2, vertical: 1),
                        decoration: BoxDecoration(
                          color: roleSoft,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Text(u.isAdmin ? 'Manager' : 'Sales',
                            style: TextStyle(
                                fontFamily: 'Carlito',
                                fontSize: 10.5,
                                height: 14 / 10.5,
                                fontWeight: FontWeight.w700,
                                color: roleColor)),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.unfold_more_rounded, size: 16, color: AppColors.faint),
              ],
            ),
          )
        : InitialsAvatar(u.name, size: 36);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.s3, top: AppSpace.s2),
      child: Center(
        child: PopupMenuButton<String>(
          tooltip: 'Account — ${u.name}',
          position: PopupMenuPosition.over,
          onSelected: (v) => v == 'pw' ? widget.onChangePassword() : widget.onSignOut(),
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              enabled: false,
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.s4, AppSpace.s3, AppSpace.s4, AppSpace.s2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(u.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'Carlito', fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.ink)),
                    Text(u.email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'Carlito', fontSize: 12, height: 16 / 12, color: AppColors.muted)),
                  ],
                ),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem<String>(
              value: 'pw',
              height: 44,
              child: Row(children: [
                Icon(Icons.lock_reset_outlined, size: 19, color: AppColors.muted),
                SizedBox(width: AppSpace.s3),
                Text('Change password',
                    style: TextStyle(fontFamily: 'Carlito', fontSize: 13.5, color: AppColors.body)),
              ]),
            ),
            const PopupMenuItem<String>(
              value: 'out',
              height: 44,
              child: Row(children: [
                Icon(Icons.logout_rounded, size: 19, color: AppColors.danger),
                SizedBox(width: AppSpace.s3),
                Text('Sign out',
                    style: TextStyle(
                        fontFamily: 'Carlito', fontSize: 13.5, fontWeight: FontWeight.w700, color: AppColors.danger)),
              ]),
            ),
          ],
          child: card,
        ),
      ),
    );
  }

  // ------------------------------------------------------------------
  // Assemble
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final showManage = widget.onSettings != null || widget.onStaff != null;

    return Container(
      width: _extended ? 244.0 : 72.0,
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _brandHeader(),
          if (_extended)
            _sectionLabel('Menu')
          else
            const SizedBox(height: AppSpace.s3),
          // Scrollable middle so the footer never overflows on short windows.
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: AppSpace.s2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < widget.destinations.length; i++)
                    _navRow(
                      icon: widget.destinations[i].icon,
                      activeIcon: widget.destinations[i].activeIcon,
                      label: widget.destinations[i].label,
                      selected: i == widget.selectedIndex,
                      onTap: () => widget.onSelect(i),
                      tooltip: widget.destinations[i].label,
                    ),
                  if (showManage) ...[
                    if (_extended)
                      _sectionLabel('Manage')
                    else
                      const SizedBox(height: AppSpace.s5),
                    if (widget.onSettings != null)
                      _navRow(
                        icon: Icons.settings_outlined,
                        activeIcon: Icons.settings_rounded,
                        label: 'Settings',
                        onTap: widget.onSettings!,
                        selected: false,
                        tooltip: 'Settings',
                      ),
                    if (widget.onStaff != null)
                      _navRow(
                        icon: Icons.manage_accounts_outlined,
                        activeIcon: Icons.manage_accounts_rounded,
                        label: 'Staff accounts',
                        onTap: widget.onStaff!,
                        selected: false,
                        tooltip: 'Staff accounts',
                      ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(indent: AppSpace.s3, endIndent: AppSpace.s3),
          _footer(),
        ],
      ),
    );
  }
}
