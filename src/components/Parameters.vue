<template>
	<div class="parameters">
		<div class="fieldRow" v-for="(param, k) in parameters" v-show="toggleParamVisibility(param)" :key="k">
			<label :class="{ fieldLabel: true, highlight: param.name === selectParameter, info: param.info }">
				{{ displayLabel(param) }}
				<strong class="required" v-if="!param.info && !param.optional" title="required">*</strong>
				<div v-if="param.description" class="description">
					<Description :description="param.description" />
				</div>
			</label>
			<ParameterDataTypes v-if="!param.info" :key="'pdt-' + param.name + '-' + cwlVersion" :ref="param.name" :editable="editable" :parameter="param" v-model="value[param.name]" :context="context" @schemaSelected="updateType(param, $event)" :parent="parent" />
			<button v-if="!param.info && param.unspecified" title="Delete unspecified parameter" class="deleteBtn" type="button" @click="deleteParam(k)"><i class="fas fa-trash"></i></button>
		</div>
		<!-- #129: pre-fill `context` from a CWL tool's declared inputs -->
		<div class="fieldRow cwlPopulateRow" v-if="isCwlRunUdf">
			<label class="fieldLabel"></label>
			<div class="fieldContainer cwlPopulate">
				<button type="button" class="cwlPopulateBtn" :disabled="!cwlUdfValue || cwlLoading" @click="populateContextFromCwl" title="Read the CWL inputs and fill the context fields">
					<i class="fas fa-magic"></i> {{ cwlLoading ? 'Reading CWL inputs…' : 'Populate context from CWL' }}
				</button>
				<div v-if="cwlError" class="cwlMsg cwlError">{{ cwlError }}</div>
				<template v-else-if="cwlNotice">
					<div class="cwlMsg cwlNotice">{{ cwlNotice }}</div>
					<ul v-if="cwlHints.length" class="cwlHints">
						<li v-for="(hint, i) in cwlHints" :key="i">{{ hint }}</li>
					</ul>
				</template>
			</div>
		</div>
	</div>
</template>

<script>
import Utils from '../utils';
import Description from '@openeo/vue-components/components/Description.vue';
import ParameterDataTypes from './ParameterDataTypes.vue';
import { ProcessParameter } from '@openeo/js-commons';

export default {
	name: 'Parameters',
	components: {
		Description,
		ParameterDataTypes
	},
	props: {
		parameters: {
			type: Array,
			required: true
		},
		value: {
			type: Object,
			required: true
		},
		editable: {
			type: Boolean,
			default: true
		},
		selectParameter: {
			type: String,
			default: null
		},
		parent: {
			type: Object,
			default: null
		}
	},
	data() {
		return {
			show: true,
			schemas: {},
			cwlLoading: false,
			cwlError: null,
			cwlNotice: null,
			cwlHints: [],
			cwlVersion: 0
		};
	},
	computed: {
		...Utils.mapState(['connection']),
		context() {
			return {
				values: this.value,
				schemas: this.schemas,
				parameters: this.parameters
			};
		},
		// #129: detect a run_udf node using the EOAP-CWL runtime so we can offer
		// to pre-fill `context` from the CWL document's declared inputs.
		isCwlRunUdf() {
			let names = this.parameters.map(p => p && p.name);
			if (!names.includes('udf') || !names.includes('context') || !names.includes('runtime')) {
				return false;
			}
			let rt = this.value.runtime;
			return typeof rt === 'string' && rt.toLowerCase() === 'eoap-cwl';
		},
		cwlUdfValue() {
			let u = this.value.udf;
			return (typeof u === 'string' && u.trim().length) ? u : null;
		}
	},
	watch: {
		value: {
			deep: true,
			handler() {
				this.$emit('input', this.value);
			}
		}
	},
	mounted() {
		this.$nextTick(() => this.setSelected());
	},
	methods: {
		toggleParamVisibility(param) {
			if (!param || !param.toggledBy) {
				return true;
			}

			return !!this.value[param.toggledBy];
		},
		deleteParam(key) {
			let name = this.parameters[key].name;
			this.$delete(this.parameters, key);
			this.$delete(this.schemas, name);
			this.$delete(this.value, name);
		},
		// #129: fetch the CWL document's input schema from the backend and merge
		// the declared inputs into `context`. Inputs the executor auto-fills
		// (job_id/user_id/openeo_data, see #127) are skipped; existing
		// user-entered values are never overwritten.
		async populateContextFromCwl() {
			this.cwlError = null;
			this.cwlNotice = null;
			this.cwlHints = [];
			let udf = this.cwlUdfValue;
			if (!udf) {
				this.cwlError = 'Enter a CWL document or URL in the "udf" field first.';
				return;
			}
			if (!this.connection) {
				this.cwlError = 'Not connected to a backend.';
				return;
			}
			this.cwlLoading = true;
			try {
				let isUrl = /^https?:\/\//i.test(udf.trim());
				let body = isUrl ? { url: udf.trim() } : { cwl: udf };
				let response = await this.connection._post('/cwl/inputs', body);
				let inputs = (response && response.data && response.data.inputs) || {};
				// Build a JSON-schema object for `context` so the editor renders each
				// input as its own field — with the description inline, enum as a
				// dropdown, defaults and required markers — handled natively by the
				// object editor via schema.properties.
				let properties = {};
				let required = [];
				let added = 0, autofilled = 0;
				for (let name of Object.keys(inputs)) {
					let spec = inputs[name];
					if (spec.autofilled) { autofilled++; continue; }   // backend fills these (#127)
					let prop = { title: name };
					if (spec.doc) { prop.description = spec.doc; }
					if (Array.isArray(spec.enum) && spec.enum.length > 0) {
						prop.type = 'string';
						prop.enum = spec.enum;
						prop.default = spec.has_default ? spec.default : spec.enum[0];
					} else {
						prop.type = this.cwlJsonType(spec.type);
						if (spec.has_default) { prop.default = spec.default; }
					}
					properties[name] = prop;
					if (spec.required) { required.push(name); }
					added++;
				}
				let idx = this.parameters.findIndex(p => p && p.name === 'context');
				if (idx === -1) {
					this.cwlError = 'No "context" parameter to populate.';
					return;
				}
				let schema = { type: 'object', properties: properties };
				if (required.length) { schema.required = required; }
				// Replace the generic context parameter with one whose schema
				// describes the CWL inputs, then empty its value so the object
				// editor prefills the described fields (attaching the inline
				// descriptions, dropdowns and defaults).
				let newParam = new ProcessParameter({ name: 'context', optional: true, schema: schema });
				this.$set(this.parameters, idx, newParam);
				this.$set(this.value, 'context', {});
				// Force the context field to remount so it re-detects the new schema
				// (ParameterDataTypes only runs type detection on create).
				this.cwlVersion++;
				this.cwlNotice = `Context structured from CWL: ${added} field(s)` +
					(autofilled ? `, ${autofilled} auto-filled by the backend` : '') + '.';
			} catch (error) {
				let detail = (error && error.message) ? error.message : String(error);
				this.cwlError = `Could not read CWL inputs: ${detail}`;
			} finally {
				this.cwlLoading = false;
			}
		},
		cwlJsonType(type) {
				// Map a CWL type name (as normalised by the backend) to a JSON-schema type.
				switch (type) {
					case 'int': case 'long': return 'integer';
					case 'float': case 'double': return 'number';
					case 'boolean': return 'boolean';
					case 'array': return 'array';
					default: return 'string';   // string, File, enum, …
				}
			},
			cwlEmptyForType(type) {
			let t = Array.isArray(type) ? type.find(x => x !== 'null') : type;
			if (typeof t === 'string') {
				t = t.replace(/\?$/, '');
			}
			switch (t) {
				case 'int': case 'long': case 'float': case 'double': return null;
				case 'boolean': return false;
				default: return '';
			}
		},
		updateType(parameter, schema) {
			this.$set(this.schemas, parameter.name, schema);
		},
		displayLabel(param) {
			if (typeof param.label === 'string' && param.label.length > 0) {
				return param.label;
			}
			else {
				return Utils.prettifyString(param.name);
			}
		},
		componentforParameter(name) {
			if (name && Array.isArray(this.$refs[name]) && this.$refs[name][0]) {
				return this.$refs[name][0];
			}
			return null;
		},
		setSelected(callCounter = 0) {
			let component;
			if (this.selectParameter) {
				component = this.componentforParameter(this.selectParameter);
			}
			else if (this.parameters.length > 0) {
				component = this.componentforParameter(this.parameters[0].name);
			}
			if (!component) {
				return;
			}
	
			if (component.$el && component.$el.scrollIntoView) {
				if (this.selectParameter) {
					component.$el.scrollIntoView();
				}
				this.setInputFocus(component.$el);
			}
			else {
				// Retry the selection, up to 2.5 seconds
				callCounter < 10 && setTimeout(() => this.setSelected(++callCounter), 250);
			}
		},
		setInputFocus(node, callCounter = 0) {
			if (node.querySelector) {
				let firstElement = node.querySelector('input:not([type="hidden"]):not([disabled]):not([class~="multiselect__input"]), button:not([disabled]), textarea:not([disabled]), select:not([disabled]), datalist:not([disabled])');
				if (firstElement) {
					firstElement.focus();
				}
			}
			else {
				// Retry focussing, up to 2.5 seconds
				callCounter < 10 && setTimeout(() => this.setInputFocus(node, ++callCounter), 250);
			}
		}
	}
};
</script>

<style lang="scss" scoped>
.deleteBtn {
	margin-left: 10px;
}
.cwlPopulate {
	display: flex;
	flex-direction: column;
	align-items: flex-start;

	.cwlPopulateBtn {
		cursor: pointer;

		&:disabled {
			cursor: default;
			opacity: 0.6;
		}
	}
	.cwlMsg {
		margin-top: 0.5em;
		font-size: 0.85em;
	}
	.cwlError {
		color: #b00;
	}
	.cwlNotice {
		color: #060;
	}
	.cwlHints {
		margin: 0.4em 0 0;
		padding-left: 1.2em;
		font-size: 0.8em;
		color: #555;

		li {
			margin: 0.15em 0;
		}
	}
}
</style>

<style lang="scss">
@use '../../theme' as *;

.parameters {
	.fieldRow {
		display: flex;
		padding-top: 1em;
		margin-top: 1em;
		border-top: 1px dotted #ccc;

		&:first-of-type {
			border: 0;
			margin: 0;
			padding: 0;
		}

		.description {
			font-size: 0.8em;
			width: 100%;
		}
		.required {
			color: red;
			font-weight: bold;
		}
		.fieldLabel {
			min-width: 30%;
			width: 30%;
			padding-right: 1em;

			&.highlight {
				width: calc(35% - 5px);
				border-left: 5px solid $linkColor;
				padding-left: 5px;
			}
			&.info {
				width: 100%;
			}
		}
		.fieldEditorContainer {
			flex-grow: 1;
			display: flex;
		}
		.fieldContainer {
			min-width: 50%;
			width: 70%;
			flex-grow: 1;
		}
		.fieldValue {
			display: flex;
			flex-grow: 1;

			input,
			textarea,
			select {
				flex-grow: 1;
				width: 100%;
			}
		}
		
		input[type="checkbox"].fieldValue  {
			display: inline-block;
			flex-grow: unset;
		}
	}

	.description .styled-description {
		line-height: 1.1em;

		p {
			margin: 0.2em 0;
		}
	}
}
</style>