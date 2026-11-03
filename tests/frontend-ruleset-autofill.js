#!/usr/bin/env node
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Rule set form: switching Type from Remote to Local fills the local Path with
 * the remote form's Initial path.
 *
 * A rule-set created as remote carries an Initial path (the local file that
 * seeds it, so the first start does not block on a download).  Switching it to
 * Local leaves the Path field empty even though the file the user means is
 * already named one field away.  The form now offers it.
 *
 * Two things are pinned, because the behaviour needs both halves:
 *
 *  1. hp.autofillLocalRulePath() - what it fills, and, as important, what it
 *     leaves alone.  It only ever writes into an EMPTY Path: a value the user
 *     typed or picked must survive flipping the type back and forth.  It reads
 *     the UI elements (the user has not saved yet) and treats a missing widget
 *     as "nothing to do", never as an error.
 *
 *  2. The wiring in client/subscription.js - that the real `type` option has an
 *     onchange handler, that it reacts to `local` only, and that it hands the
 *     handler the section it belongs to.  A correct helper behind a handler
 *     that is never attached does nothing for the user.
 *
 * No browser: the form is a recording mock, and the "UI elements" are plain
 * objects with getValue/setValue.
 *
 * Usage: node tests/frontend-ruleset-autofill.js <repo-root>
 */

'use strict';

const path = require('path');
const { loadLuciModule } = require('./lib/luci-module.js');

const root = path.resolve(process.argv[2] || '.');

let checks = 0, failures = 0;
function check(what, ok, detail) {
	checks++;
	if (ok) return;
	failures++;
	console.error(`FAIL ${what}${detail ? ': ' + detail : ''}`);
}

const RES = path.join(root, 'htdocs/luci-static/resources');

const hp = loadLuciModule(path.join(RES, 'homeproxy.js'), {
	baseclass: { extend: (o) => o },
	form: { DynamicList: { extend: (o) => o } },
	fs: {}, rpc: {}, uci: {}, ui: {}
});

/* --- a section whose options hold UI-element stand-ins ------------------ */
function widget(value, extra) {
	const w = {
		value,
		sets: 0,
		validated: 0,
		getValue() { return this.value; },
		setValue(v) { this.value = v; this.sets++; }
	};
	return Object.assign(w, extra || {});
}

function fakeSection(widgets) {
	return {
		getOption(name) {
			if (!Object.prototype.hasOwnProperty.call(widgets, name))
				return null;
			return { getUIElement: () => widgets[name] };
		}
	};
}

const INITIAL = '/etc/homeproxy/ruleset/geosite-cn.srs';

/* ====================================================================== *
 * 1. the helper
 * ====================================================================== */

check('the helper is exported by homeproxy.js', typeof hp.autofillLocalRulePath === 'function');

{
	const w = { path: widget(''), initial_path: widget(INITIAL) };
	const r = hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('an empty Path is filled with the Initial path', w.path.value === INITIAL, w.path.value);
	check('...and the helper reports that it filled', r === true);
}

{
	const w = { path: widget('   '), initial_path: widget(INITIAL) };
	hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('a whitespace-only Path counts as empty', w.path.value === INITIAL, JSON.stringify(w.path.value));
}

{
	const w = { path: widget(null), initial_path: widget(INITIAL) };
	hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('a null Path (widget with no value yet) counts as empty', w.path.value === INITIAL);
}

{
	const typed = '/etc/homeproxy/ruleset/mine.json';
	const w = { path: widget(typed), initial_path: widget(INITIAL) };
	const r = hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('a Path the user already has is never overwritten', w.path.value === typed, w.path.value);
	check('...and nothing is written at all', w.path.sets === 0);
	check('...and the helper reports that it did not fill', r === false);
}

{
	const w = { path: widget(''), initial_path: widget('') };
	const r = hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('an empty Initial path leaves Path alone', w.path.value === '' && w.path.sets === 0);
	check('...and reports that it did not fill', r === false);
}

{
	const w = { path: widget(''), initial_path: widget('  ' + INITIAL + '\n') };
	hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('the Initial path is trimmed before it is copied', w.path.value === INITIAL, JSON.stringify(w.path.value));
}

{
	const w = { path: widget('') };
	let threw = null, r;
	try { r = hp.autofillLocalRulePath(fakeSection(w), 'sec1'); } catch (e) { threw = e; }
	check('no Initial path widget at all is "nothing to do", not an error', threw === null && r === false, threw && threw.message);
}

{
	const w = { initial_path: widget(INITIAL) };
	let threw = null, r;
	try { r = hp.autofillLocalRulePath(fakeSection(w), 'sec1'); } catch (e) { threw = e; }
	check('no Path widget at all is "nothing to do", not an error', threw === null && r === false, threw && threw.message);
}

{
	let threw = null, r1, r2;
	try {
		r1 = hp.autofillLocalRulePath(null, 'sec1');
		r2 = hp.autofillLocalRulePath(fakeSection({}), undefined);
	} catch (e) { threw = e; }
	check('a missing section or section id is a no-op', threw === null && r1 === false && r2 === false, threw && threw.message);
}

{
	/* The validator on Path runs on keystrokes; a programmatic fill would
	 * otherwise show no verdict until the next one. */
	const w = { path: widget('', { triggerValidation() { this.validated++; } }), initial_path: widget(INITIAL) };
	hp.autofillLocalRulePath(fakeSection(w), 'sec1');
	check('the Path widget is asked to validate the filled value', w.path.validated === 1, String(w.path.validated));
}

{
	/* ...but not every widget has it, and the fill must not depend on it. */
	const w = { path: widget(''), initial_path: widget(INITIAL) };
	check('a widget without triggerValidation still gets filled',
		(hp.autofillLocalRulePath(fakeSection(w), 'sec1'), w.path.value === INITIAL));
}

{
	/* Flip Remote -> Local -> Remote -> Local: the second Local must not
	 * overwrite what is there now. */
	const w = { path: widget(''), initial_path: widget(INITIAL) };
	const sec = fakeSection(w);
	hp.autofillLocalRulePath(sec, 'sec1');
	w.path.value = '/etc/homeproxy/ruleset/edited.srs';
	hp.autofillLocalRulePath(sec, 'sec1');
	check('flipping the type back and forth never clobbers an edit',
		w.path.value === '/etc/homeproxy/ruleset/edited.srs', w.path.value);
}

/* ====================================================================== *
 * 2. the wiring in client/subscription.js
 * ====================================================================== */

class MockOption {
	constructor(kind, name) {
		this.__kind = kind && kind.__name__ ? kind.__name__ : String(kind);
		this.__name = name;
		this.option = name;
		if (this.__kind === 'SectionValue')
			this.subsection = new MockSection('GridSection', name);
	}
	depends() {}
	value() {}
}

class MockSection {
	constructor(kind, name) {
		this.__kind = kind;
		this.__name = name;
		this.options = [];
		this.widgets = {};
	}
	tab() {}
	taboption(_tab, ...args) { return this.option(...args); }
	option(kind, name) {
		const o = new MockOption(kind, name);
		o.section = this;
		this.options.push(o);
		return o;
	}
	/* AbstractSection.getOption + AbstractValue.getUIElement, as the helper
	 * calls them. */
	getOption(name) {
		if (!Object.prototype.hasOwnProperty.call(this.widgets, name))
			return null;
		return { getUIElement: () => this.widgets[name] };
	}
}

const form = {};
for (const name of [ 'Value', 'ListValue', 'Flag', 'DynamicList', 'MultiValue', 'TextValue',
		'DummyValue', 'Button', 'TypedSection', 'NamedSection', 'GridSection', 'SectionValue' ]) {
	form[name] = class {};
	form[name].__name__ = name;
}

const L = { bind: (fn, self, ...bound) => fn.bind(self, ...bound) };

const view = loadLuciModule(path.join(RES, 'view/homeproxy/client/subscription.js'), {
	baseclass: { extend: (o) => o },
	form,
	uci: { sections: () => {} },
	homeproxy: hp
}, { L, E: () => null });

const ctx = { s: new MockSection('TypedSection', undefined) };
let threw = null;
try { view.render(ctx); } catch (e) { threw = e; }
check('subscription.js renders against the mock without throwing', threw === null, threw && threw.stack);

const grid = ctx.s.options.find((o) => o.__name === '_ruleset');
const ruleset = grid && grid.subsection;
check('the Rule Set grid section exists', !!ruleset);

const typeOpt = ruleset && ruleset.options.find((o) => o.__name === 'type');
check('the rule-set Type option exists', !!typeOpt);
check('the Type option has an onchange handler', typeOpt && typeof typeOpt.onchange === 'function',
	typeOpt && typeof typeOpt.onchange);

if (typeOpt && typeof typeOpt.onchange === 'function') {
	ruleset.widgets = { path: widget(''), initial_path: widget(INITIAL) };

	typeOpt.onchange({}, 'sec1', 'local');
	check('choosing Local through the real handler fills Path',
		ruleset.widgets.path.value === INITIAL, ruleset.widgets.path.value);

	ruleset.widgets = { path: widget(''), initial_path: widget(INITIAL) };
	typeOpt.onchange({}, 'sec1', 'remote');
	check('choosing Remote does not touch Path',
		ruleset.widgets.path.value === '' && ruleset.widgets.path.sets === 0);

	ruleset.widgets = { path: widget(''), initial_path: widget(INITIAL) };
	typeOpt.onchange({}, undefined, 'local');
	check('a handler call with no section id does nothing', ruleset.widgets.path.sets === 0);

	ruleset.widgets = { path: widget('/etc/homeproxy/ruleset/kept.srs'), initial_path: widget(INITIAL) };
	typeOpt.onchange({}, 'sec1', 'local');
	check('through the real handler, an existing Path is kept',
		ruleset.widgets.path.value === '/etc/homeproxy/ruleset/kept.srs');
}

console.log(`${checks} checks, ${failures} failures`);
process.exit(failures ? 1 : 0);
