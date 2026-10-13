// #734. The panel button shows the icon + active account's name + session % (recommended % when unknown).
// Opening the menu runs `node model.mjs` (local file read only). The two buttons run
// `node refresh.mjs usage|billing`, which call the installed claudestatus code.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';

// install_claudestatus_bar copies model.mjs, refresh.mjs and labels.mjs here (not beside the extension,
// which is copied to ~/.local/share/gnome-shell/extensions/).
const HELPER_DIR = `${GLib.get_user_data_dir()}/claudestatus-bar/claudestatus_bar`;

// done(stdout) on success; done(null, message) when node cannot run or exits non-zero.
function node(helperPath, script, args, done) {
    const nodeBin = GLib.find_program_in_path('node') ?? `${GLib.get_home_dir()}/.asdf/shims/node`;
    const proc = Gio.Subprocess.new(
        [nodeBin, `${helperPath}/${script}`, ...args],
        Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
    proc.communicate_utf8_async(null, null, (p, res) => {
        try {
            const [, out, err] = p.communicate_utf8_finish(res);
            if (p.get_successful())
                done(out);
            else
                done(null, (err || '').trim().split('\n').pop() || `exit ${p.get_exit_status()}`);
        } catch (e) {
            logError(e, 'claudestatus-bar');
            done(null, e.message);
        }
    });
}

const Indicator = GObject.registerClass(
class Indicator extends PanelMenu.Button {
    _init(helperPath) {
        super._init(0.0, 'claudestatus bar');
        this._dir = helperPath;
        const box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        box.add_child(new St.Icon({icon_name: 'utilities-system-monitor-symbolic', style_class: 'system-status-icon'}));
        this._label = new St.Label({text: '—', y_align: Clutter.ActorAlign.CENTER});
        box.add_child(this._label);
        this.add_child(box);

        this._blocks = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._blocks);
        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._addButton('Refresh usage', 'usage');
        this._addButton('Refresh billing', 'billing');
        this._addItem = new PopupMenu.PopupMenuItem('+ Add account');
        this._addItem.connect('activate', () => this._addAccountDialog());
        this.menu.addMenuItem(this._addItem);

        this.menu.connect('open-state-changed', (_m, open) => open && this._reload());
        this._reload();
    }

    _addButton(title, kind) {
        const item = new PopupMenu.PopupMenuItem(title);
        item.connect('activate', () => {
            this._label.text = '…';
            node(this._dir, 'refresh.mjs', [kind], (_out, err) => {
                if (this._destroyed)
                    return;
                this._reload(err ? `Refresh ${kind} failed: ${err}` : null);
            });
        });
        this.menu.addMenuItem(item);
    }

    // Name (required) + optional label. The dialog only collects them; _runAdd does the login.
    _addAccountDialog() {
        this.menu.close();
        const dialog = new ModalDialog.ModalDialog({styleClass: 'prompt-dialog'});
        this._dialog = dialog;
        dialog.connect('closed', () => {
            if (this._dialog === dialog)
                this._dialog = null;
            dialog.destroy();
        });
        const box = new St.BoxLayout({vertical: true, style: 'spacing: 8px;'});
        const nameEntry = new St.Entry({hint_text: 'Account name', can_focus: true});
        const labelEntry = new St.Entry({hint_text: 'Label (optional)', can_focus: true});
        const status = new St.Label({text: ''});
        [new St.Label({text: 'Add Claude account'}), nameEntry, labelEntry, status]
            .forEach(w => box.add_child(w));
        dialog.contentLayout.add_child(box);
        dialog.addButton({label: 'Cancel', key: Clutter.KEY_Escape, action: () => dialog.close()});
        dialog.addButton({
            label: 'Add and log in',
            default: true,
            action: () => {
                const name = nameEntry.text.trim();
                if (!name || name.includes('/')) {
                    status.text = name ? "Name must not contain '/'" : 'Name is required';
                    return;
                }
                dialog.close();
                this._runAdd(name, labelEntry.text.trim());
            },
        });
        dialog.open();
        nameEntry.grab_key_focus();
    }

    // refresh.mjs validates, runs `claudestatus add` (opens the browser login) and saves the label;
    // failures come back as its last stderr line. A modal dialog grabs all input, so it is closed
    // before the login starts (the browser must stay usable) and progress shows on the panel
    // button. The menu item stays insensitive until the add and its usage snapshot finish, so two
    // adds never overlap.
    _runAdd(name, label) {
        this._addItem.setSensitive(false);
        this._label.text = '…';
        const finish = refreshError => {
            this._addItem.setSensitive(true);
            if (refreshError)
                Main.notify('claudestatus', refreshError);
            this._reload(refreshError);
        };
        node(this._dir, 'refresh.mjs', ['add', name, label], (_out, err) => {
            if (this._destroyed)
                return;
            if (err)
                return finish(`Add account failed: ${err}`);
            // The list of accounts comes from usage.json, so snapshot it for the new one to show.
            node(this._dir, 'refresh.mjs', ['usage'], (_o, usageErr) => {
                if (!this._destroyed)
                    finish(usageErr ? `Refresh usage failed: ${usageErr}` : null);
            });
        });
    }

    // Click the label row -> entry; Enter saves, Esc cancels, empty clears (labels.mjs set).
    _labelRow(name, label) {
        const item = new PopupMenu.PopupMenuItem(label ? `🏷 ${label}` : '🏷 add label…');
        // Overriding activate (as PopupSwitchMenuItem does) keeps the menu open for the entry.
        item.activate = () => {
            if (item._editing)
                return;
            item._editing = true;
            const entry = new St.Entry({text: label ?? '', hint_text: 'Label', can_focus: true, x_expand: true});
            item.label.hide();
            item.add_child(entry);
            entry.grab_key_focus();
            entry.clutter_text.connect('key-press-event', (_t, ev) => {
                const key = ev.get_key_symbol();
                if (key === Clutter.KEY_Escape) {
                    this._reload();
                    return Clutter.EVENT_STOP;
                }
                if (key === Clutter.KEY_Return || key === Clutter.KEY_KP_Enter) {
                    node(this._dir, 'labels.mjs', ['set', name, entry.text], (_out, err) => {
                        if (this._destroyed)
                            return;
                        if (!err) {
                            this._reload();
                            return;
                        }
                        // Keep the edit on screen so the typed label is not lost.
                        Main.notify('claudestatus', `Label not saved: ${err}`);
                    });
                    return Clutter.EVENT_STOP;
                }
                return Clutter.EVENT_PROPAGATE;
            });
        };
        return item;
    }

    destroy() {
        // Pending node() callbacks outlive the indicator; they check this before touching it.
        this._destroyed = true;
        this._dialog?.close();
        super.destroy();
    }

    _reload(refreshError = null) {
        // labels.mjs get: a hand edit of labels.json shows on the next open; failure = no labels.
        node(this._dir, 'labels.mjs', ['get'], lout => this._render(refreshError, lout));
    }

    _render(refreshError, lout) {
        let labels = {};
        try {
            labels = lout ? JSON.parse(lout) : {};
        } catch (_e) { /* malformed output: show no labels */ }
        node(this._dir, 'model.mjs', [], out => {
            if (this._destroyed)
                return;
            this._blocks.removeAll();
            if (refreshError)
                this._blocks.addMenuItem(new PopupMenu.PopupMenuItem(`✗ ${refreshError}`, {reactive: false}));
            if (!out) {
                this._label.text = '—';
                this._blocks.addMenuItem(new PopupMenu.PopupMenuItem('model.mjs failed (is node on PATH?)', {reactive: false}));
                return;
            }
            const model = JSON.parse(out);
            this._label.text = model.bar;
            if (model.activeLine)  // absent when a stale deployed model.mjs predates #752
                this._blocks.addMenuItem(new PopupMenu.PopupMenuItem(model.activeLine, {reactive: false}));
            if (model.accounts.length === 0)
                this._blocks.addMenuItem(new PopupMenu.PopupMenuItem('No data yet: press Refresh usage', {reactive: false}));
            for (const a of model.accounts) {
                const item = new PopupMenu.PopupMenuItem(a.text, {reactive: false});
                item.label.style = 'font-family: monospace;';
                this._blocks.addMenuItem(item);
                this._blocks.addMenuItem(this._labelRow(a.name, labels[a.name]));
            }
        });
    }
});

export default class ClaudestatusBar extends Extension {
    enable() {
        this._indicator = new Indicator(HELPER_DIR);
        Main.panel.addToStatusArea(this.uuid, this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}
