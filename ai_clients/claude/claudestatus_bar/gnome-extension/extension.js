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

// install_claudestatus_bar copies model.mjs and refresh.mjs here (not beside the extension,
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

    destroy() {
        // Pending node() callbacks outlive the indicator; they check this before touching it.
        this._destroyed = true;
        super.destroy();
    }

    _reload(refreshError = null) {
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
