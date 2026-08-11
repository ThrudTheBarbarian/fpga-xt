// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://atari-xt.com',
	integrations: [
		starlight({
			title: 'Atari-XT',
			description:
				'A modern take on Atari computers, implemented on a single Xilinx Zynq-7020 — the SALLY 6502 and ANTIC/GTIA/POKEY pipeline in FPGA fabric, the modern half on dual Cortex-A9, plus the xtc compiler and toolchain.',
			customCss: ['./src/styles/xtc.css'],
			// Browser-tab icon, cropped to the golden jigsaw piece (see public/).
			favicon: '/favicon.png',
			head: [
				{
					tag: 'link',
					attrs: { rel: 'apple-touch-icon', sizes: '180x180', href: '/apple-touch-icon.png' },
				},
			],
			// Starlight 0.38's preprocess-wrapped schema treats `social` as
			// required even though the underlying type is optional; pass an
			// empty array to satisfy validation.
			social: [],
			sidebar: [
				{ label: 'Introduction', slug: 'index' },
				{
					label: 'Hardware',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'hardware' },
						{
							label: 'Shared platform & fabric',
							collapsed: true,
							items: [
								{ label: 'ARM — Cortex-A9 PS', slug: 'hardware/arm' },
								{ label: 'Blitter (xt-blitter)', slug: 'hardware/blitter' },
								{ label: 'Math co-processor (MECH)', slug: 'hardware/mech' },
								{ label: 'Display & compositor', slug: 'hardware/video' },
								{ label: 'HDMI output', slug: 'hardware/hdmi' },
								{ label: 'Audio', slug: 'hardware/audio' },
								{ label: 'Carrier board', slug: 'hardware/carrier' },
								{ label: 'Memory map', slug: 'hardware/memory-map' },
								{ label: 'Pin map', slug: 'hardware/pin-map' },
								{ label: 'Hardware bring-up', slug: 'hardware/bring-up' },
							],
						},
						{
							label: 'X — Atari 8-bit (Sally / ANTIC / POKEY)',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'hardware/x' },
								{ label: '6502 / SALLY extensions', slug: 'hardware/cpu' },
								{ label: 'ANTIC', slug: 'hardware/antic' },
								{ label: 'Register map', slug: 'hardware/register-map' },
								{ label: 'Palette (NTSC / PAL)', slug: 'hardware/palette' },
							],
						},
						{
							label: 'T — Atari ST/TT (m68k)',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'hardware/t' },
							],
						},
					],
				},
				{
					label: 'Compiler (xtc)',
					items: [
						{ label: 'Overview', slug: 'compiler' },
						{
							label: 'Language',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'compiler/language' },
								{ label: 'Lexical structure', slug: 'compiler/language/lexical' },
								{ label: 'Preprocessor', slug: 'compiler/language/preprocessor' },
								{ label: 'Types', slug: 'compiler/language/types' },
								{ label: 'Operators', slug: 'compiler/language/operators' },
								{ label: 'Statements & control flow', slug: 'compiler/language/statements' },
								{ label: 'Functions', slug: 'compiler/language/functions' },
								{ label: 'Classes', slug: 'compiler/language/classes' },
								{ label: 'Inheritance & protocols', slug: 'compiler/language/inheritance' },
								{ label: 'Bound methods & callbacks', slug: 'compiler/language/bound-methods' },
								{ label: 'Errors (throws / try / catch)', slug: 'compiler/language/errors' },
								{ label: 'Heap, ARC & weak refs', slug: 'compiler/language/memory' },
								{ label: 'Collections & strings', slug: 'compiler/language/collections' },
								{ label: 'Threading', slug: 'compiler/language/threading' },
								{ label: 'Modules & shared libraries', slug: 'compiler/language/modules' },
								{ label: 'Inline assembly', slug: 'compiler/language/inline-asm' },
							],
						},
						{
							label: 'Standard library',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'compiler/api' },
								{ label: 'Stdio', slug: 'compiler/api/stdio' },
								{ label: 'Math', slug: 'compiler/api/math' },
								{ label: 'Time', slug: 'compiler/api/time' },
								{ label: 'Heap', slug: 'compiler/api/heap' },
								{ label: 'Vbi', slug: 'compiler/api/vbi' },
								{ label: 'System', slug: 'compiler/api/system' },
								{ label: 'Assert', slug: 'compiler/api/assert' },
								{ label: 'Sort', slug: 'compiler/api/sort' },
								{ label: 'Memory', slug: 'compiler/api/memory' },
								{ label: 'Foundation (Number / String / Data / Array)', slug: 'compiler/api/foundation' },
							],
						},
						{
							label: 'Compiler usage',
							collapsed: true,
							items: [
								{ label: 'Overview', slug: 'compiler/usage' },
								{ label: 'Install', slug: 'compiler/usage/install' },
								{ label: 'CLI flag reference', slug: 'compiler/usage/cli' },
								{ label: 'Optimisation', slug: 'compiler/usage/optimization' },
								{ label: 'Memory models', slug: 'compiler/usage/memory-models' },
								{ label: 'Allocator & ARC', slug: 'compiler/usage/allocator-arc' },
								{ label: 'Linker scripts (.lnk)', slug: 'compiler/usage/linker-scripts' },
							],
						},
						{ label: 'Future work', slug: 'compiler/future-work' },
						{
							label: 'Downloads',
							collapsed: true,
							items: [
								{ label: 'Most Recent Release', slug: 'compiler/downloads' },
								{ label: 'Historical Releases', slug: 'compiler/downloads/historical' },
								{ label: 'ChangeLog', slug: 'compiler/downloads/changelog' },
							],
						},
					],
				},
				{
					label: 'Operating system',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'os' },
						{ label: 'Runtime: loading & memory protection', slug: 'os/runtime' },
						{ label: 'Threads', slug: 'os/threads' },
						{
							label: 'Multitasking',
							items: [
								{ label: 'Overview', slug: 'os/multitasking' },
								{ label: 'ARM Cortex-A9', slug: 'os/multitasking/arm' },
								{
									label: '6502',
									items: [
										{ label: 'Context switching', slug: 'os/multitasking/6502/context-switch' },
										{ label: 'XT multitasking', slug: 'os/multitasking/6502/xt-multitasking' },
									],
								},
								{ label: 'm68k / FreeMiNT', slug: 'os/multitasking/m68k' },
							],
						},
						{
							label: 'GEM (VDI / AES)',
							items: [
								{ label: 'Overview', slug: 'os/gem' },
								{ label: 'VDI reference', slug: 'os/gem/vdi' },
								{ label: 'AES reference', slug: 'os/gem/aes' },
								{ label: 'Theming', slug: 'os/gem/theme' },
							],
						},
						{ label: 'VDI / blitter driver', slug: 'os/vdi-blitter' },
						{ label: 'Self-hosting roadmap', slug: 'os/self-hosting' },
					],
				},
				{
					label: 'Project & status',
					collapsed: true,
					items: [
						{ label: 'Overview', slug: 'project' },
						{ label: 'Current state', slug: 'project/current-state' },
						{ label: 'Future work / roadmap', slug: 'project/future-work' },
						{ label: 'Resident page cache', slug: 'project/page-cache' },
						{ label: 'Sprite engine', slug: 'project/sprite-engine' },
						{ label: 'Issue: PSH guard byte', slug: 'project/issues/psh-guard-byte' },
					],
				},
				{ label: 'Report a bug', slug: 'feedback' },
			],
		}),
	],
});
