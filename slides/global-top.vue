<!-- The persistent slide chrome: the agenda section (bottom-left), the slide counter
     (bottom-right) and a progress bar along the bottom edge. Slidev loads this file by
     name; the classes live in style.css.

     The section label is declared ONCE per section in slides.md as `section:` frontmatter
     and inherited by every slide after it — so inserting a slide needs no edit here.
     `section: ''` clears it again (the thank-you slide does that).

     The counter and the progress bar count to the thank-you slide (the first
     `layout: end`), not to the last slide: everything after it is backup, shown only if
     asked, so neither is drawn there. -->
<script setup lang="ts">
import { useNav } from '@slidev/client'
import { computed } from 'vue'

const { currentPage, currentLayout, slides, total } = useNav()

// Layouts that announce themselves — the label would only repeat what they already say.
const bare = computed(() => ['cover', 'section', 'end'].includes(currentLayout.value))

const section = computed(() => {
  for (let i = currentPage.value - 1; i >= 0; i--) {
    const fm = slides.value[i]?.meta?.slide?.frontmatter
    if (fm && 'section' in fm)
      return fm.section
  }
  return ''
})

// The thank-you slide's page number; the whole deck when there is none.
const last = computed(() => {
  const i = slides.value.findIndex(s => s?.meta?.slide?.frontmatter?.layout === 'end')
  return i >= 0 ? i + 1 : total.value
})
const counted = computed(() => currentPage.value <= last.value)
</script>

<template>
  <div v-if="section && !bare" class="k-section">{{ section }}</div>
  <div v-if="currentPage > 1 && counted" class="k-counter">{{ currentPage }} / {{ last }}</div>
  <div v-if="counted" class="k-progress" :style="{ width: (currentPage / last * 100) + '%' }" />
</template>
