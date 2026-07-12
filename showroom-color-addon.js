/* UMHOME Showroom Smart Filter Add-on v6
   กรองต่อเนื่อง: ยี่ห้อ -> รุ่นรถ -> สี
   วางไฟล์นี้ไว้ข้าง index.html และเพิ่มก่อน </body>:
   <script src="showroom-color-addon.js?v=6"></script>
*/
(function () {
  'use strict';

  const COLOR_ORDER = [
    'ขาว', 'ดำ', 'เทา', 'เงิน', 'แดง', 'น้ำเงิน', 'ฟ้า', 'เขียว',
    'น้ำตาล', 'ทอง', 'ส้ม', 'เหลือง', 'ม่วง', 'ชมพู', 'ทูโทน', 'อื่น ๆ'
  ];

  const COLOR_DOTS = {
    'ขาว':'#fff', 'ดำ':'#242424', 'เทา':'#8b9098', 'เงิน':'#c4c9cf',
    'แดง':'#d94a4a', 'น้ำเงิน':'#355faa', 'ฟ้า':'#58aee8', 'เขียว':'#4c956c',
    'น้ำตาล':'#8b5e3c', 'ทอง':'#c79a3b', 'ส้ม':'#ed7d31', 'เหลือง':'#e4c536',
    'ม่วง':'#7c58a1', 'ชมพู':'#d987a4', 'ทูโทน':'linear-gradient(135deg,#fff 0 50%,#333 50%)',
    'อื่น ๆ':'#b8b2aa'
  };

  let selectedBrand = 'all';
  let selectedModel = 'all';
  let selectedColor = 'all';
  let installed = false;

  function clean(value) {
    return String(value || '').trim().replace(/\s+/g, ' ');
  }

  function keyOf(value) {
    return clean(value).toLocaleLowerCase('th-TH');
  }

  function inferColorGroup(value) {
    const compact = clean(value).replace(/\s+/g, '').toLowerCase();
    if (!compact) return '';
    if (/ทูโทน|สองสี|2tone|two[- ]?tone/.test(compact)) return 'ทูโทน';
    if (/บรอนซ์ทอง|แชมเปญ|champagne|gold|สีทอง|ทอง/.test(compact)) return 'ทอง';
    if (/บรอนซ์เงิน|บรอนซ์|ซิลเวอร์|silver|สีเงิน|เงิน/.test(compact)) return 'เงิน';
    if (/ฟ้า|skyblue|lightblue/.test(compact)) return 'ฟ้า';
    if (/กรมท่า|navy|น้ำเงิน|blue/.test(compact)) return 'น้ำเงิน';
    if (/ขาว|white|มุก|ครีม/.test(compact)) return 'ขาว';
    if (/เทา|gray|grey|ไทเทเนียม|gunmetal|กันเมทัล/.test(compact)) return 'เทา';
    if (/ดำ|black/.test(compact)) return 'ดำ';
    if (/แดง|red/.test(compact)) return 'แดง';
    if (/เขียว|green/.test(compact)) return 'เขียว';
    if (/น้ำตาล|brown/.test(compact)) return 'น้ำตาล';
    if (/ส้ม|orange/.test(compact)) return 'ส้ม';
    if (/เหลือง|yellow/.test(compact)) return 'เหลือง';
    if (/ม่วง|purple/.test(compact)) return 'ม่วง';
    if (/ชมพู|pink/.test(compact)) return 'ชมพู';
    return 'อื่น ๆ';
  }

  function brandName(car) {
    return clean(car && car.brand);
  }

  function modelName(car) {
    let value = clean(car && car.model);
    const brand = brandName(car);
    if (value && brand && keyOf(value).startsWith(keyOf(brand) + ' ')) {
      value = clean(value.slice(brand.length));
    }
    return value;
  }

  function colorGroup(car) {
    return clean(car && car.color_group) || inferColorGroup(car && car.color_name);
  }

  function colorName(car) {
    return clean(car && (car.color_name || car.color_group));
  }

  function searchBlob(car) {
    return [
      car && car.brand, car && car.model, car && car.sub_model, car && car.year,
      car && car.price, car && car.engine, car && car.gear,
      car && car.color_group, car && car.color_name,
      car && car.license_plate
    ].filter(Boolean).join(' ').toLowerCase();
  }

  function escapeText(value) {
    return String(value || '').replace(/[&<>"']/g, (ch) => ({
      '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'
    }[ch]));
  }

  function groupedOptions(cars, getter) {
    const map = new Map();
    (Array.isArray(cars) ? cars : []).forEach((car) => {
      const label = clean(getter(car));
      const key = keyOf(label);
      if (!key) return;
      const current = map.get(key);
      if (current) current.count += 1;
      else map.set(key, { key, label, count: 1 });
    });
    return [...map.values()].sort((a, b) => a.label.localeCompare(b.label, 'th', { numeric: true }));
  }

  function filterByBrand(cars) {
    if (selectedBrand === 'all') return cars;
    return cars.filter((car) => keyOf(brandName(car)) === selectedBrand);
  }

  function filterByModel(cars) {
    if (selectedModel === 'all') return cars;
    return cars.filter((car) => keyOf(modelName(car)) === selectedModel);
  }

  function injectStyles() {
    if (document.getElementById('um-smart-filter-style')) return;
    const style = document.createElement('style');
    style.id = 'um-smart-filter-style';
    style.textContent = `
      .showroom-color-tag{display:inline-flex!important;align-items:center;gap:5px}
      .showroom-color-dot{display:inline-block;width:11px;height:11px;border-radius:50%;border:1px solid rgba(30,25,20,.2);box-shadow:inset 0 0 0 1px rgba(255,255,255,.35);flex:none}
      .showroom-color-spec .showroom-color-dot{width:13px;height:13px;margin-right:5px;vertical-align:-1px}
      .um-smart-filter{margin:10px 0 12px;padding:11px;border:1px solid rgba(123,139,160,.18);border-radius:15px;background:rgba(255,255,255,.78);box-shadow:0 3px 12px rgba(30,50,80,.05)}
      .um-smart-filter-head{display:flex;align-items:center;justify-content:space-between;gap:10px;cursor:pointer;user-select:none}
      .um-smart-filter-summary{min-width:0;display:flex;flex-direction:column;gap:2px}
      .um-smart-filter-title{font-size:12px;font-weight:900;color:#253047}
      .um-smart-filter-desc{font-size:11px;font-weight:700;color:#718096;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .um-smart-filter-toggle{flex:none;width:34px;height:34px;border:1px solid rgba(123,139,160,.2);border-radius:999px;background:#fff;color:#253047;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;box-shadow:0 2px 8px rgba(30,50,80,.05)}
      .um-smart-filter-toggle svg{width:16px;height:16px;transition:transform .22s ease}
      .um-smart-filter:not(.is-collapsed) .um-smart-filter-toggle svg{transform:rotate(180deg)}
      .um-smart-filter-body{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:9px;margin-top:10px;overflow:hidden;transition:max-height .26s ease,opacity .2s ease,margin-top .2s ease;max-height:520px;opacity:1}
      .um-smart-filter.is-collapsed .um-smart-filter-body{max-height:0;opacity:0;margin-top:0;pointer-events:none}
      .um-smart-filter-field{display:flex;flex-direction:column;gap:5px;min-width:0}
      .um-smart-filter-field>span{padding-left:2px;color:#718096;font-size:11px;font-weight:800}
      .um-smart-filter-select{width:100%;min-width:0;height:42px;padding:0 34px 0 11px;border:1px solid rgba(123,139,160,.22);border-radius:12px;background:#fff;color:#253047;font:700 12.5px inherit;outline:none}
      .um-smart-filter-select:focus{border-color:#38bdf8;box-shadow:0 0 0 3px rgba(56,189,248,.12)}
      .um-smart-filter-select:disabled{opacity:.55}
      .um-smart-filter-reset{grid-column:1/-1;display:none;justify-self:end;border:0;background:none;padding:0 2px;color:#1683d8;font:800 11.5px inherit;cursor:pointer}
      .um-smart-filter.has-selection .um-smart-filter-reset{display:block}
      @media(max-width:680px){.um-smart-filter-body{grid-template-columns:1fr 1fr}.um-smart-filter-field:last-of-type{grid-column:1/-1}.um-smart-filter-select{height:41px}}
      @media(max-width:420px){.um-smart-filter-body{grid-template-columns:1fr}.um-smart-filter-field:last-of-type{grid-column:auto}}
    `;
    document.head.appendChild(style);
  }

  function ensureFilterUi() {
    let box = document.getElementById('umSmartVehicleFilter');
    if (box) return box;

    const price = document.getElementById('priceRange');
    const row = price && price.closest('.row');
    const anchor = row || price;
    if (!anchor || !anchor.parentNode) return null;

    box = document.createElement('div');
    box.id = 'umSmartVehicleFilter';
    box.className = 'um-smart-filter';
    box.innerHTML = `
      <div class="um-smart-filter-head" id="umSmartFilterToggle" role="button" tabindex="0" aria-expanded="false" aria-controls="umSmartFilterBody">
        <div class="um-smart-filter-summary">
          <div class="um-smart-filter-title">ตัวกรองรถ</div>
          <div class="um-smart-filter-desc" id="umSmartFilterDesc">แตะเพื่อเปิดตัวกรอง ยี่ห้อ / รุ่น / สี</div>
        </div>
        <button class="um-smart-filter-toggle" type="button" aria-label="เปิดหรือซ่อนตัวกรองรถ">
          <svg viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="M5 8l5 5 5-5" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>
        </button>
      </div>
      <div class="um-smart-filter-body" id="umSmartFilterBody">
        <label class="um-smart-filter-field"><span>ยี่ห้อ</span><select id="umBrandFilter" class="um-smart-filter-select" aria-label="กรองตามยี่ห้อรถ"></select></label>
        <label class="um-smart-filter-field"><span>รุ่นรถ</span><select id="umModelFilter" class="um-smart-filter-select" aria-label="กรองตามรุ่นรถ"></select></label>
        <label class="um-smart-filter-field"><span>สีรถ</span><select id="colorFilter" class="um-smart-filter-select" aria-label="กรองตามสีรถ"></select></label>
        <button id="umSmartFilterReset" class="um-smart-filter-reset" type="button">ล้าง ยี่ห้อ / รุ่น / สี</button>
      </div>
    `;
    anchor.insertAdjacentElement('afterend', box);

    const toggleFilter = () => {
      const collapsed = !box.classList.contains('is-collapsed');
      setFilterCollapsed(collapsed, true);
    };

    const toggle = box.querySelector('#umSmartFilterToggle');
    if (toggle) {
      toggle.addEventListener('click', (event) => {
        if (event.target.closest('select')) return;
        toggleFilter();
      });
      toggle.addEventListener('keydown', (event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          toggleFilter();
        }
      });
    }

    setFilterCollapsed(initialCollapsedState(), false);

    box.querySelector('#umBrandFilter').addEventListener('change', (event) => {
      selectedBrand = event.target.value || 'all';
      selectedModel = 'all';
      selectedColor = 'all';
      fillFilterOptions();
      apply();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });

    box.querySelector('#umModelFilter').addEventListener('change', (event) => {
      selectedModel = event.target.value || 'all';
      selectedColor = 'all';
      fillFilterOptions();
      apply();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });

    box.querySelector('#colorFilter').addEventListener('change', (event) => {
      selectedColor = event.target.value || 'all';
      fillFilterOptions();
      apply();
      window.scrollTo({ top: 0, behavior: 'smooth' });
    });

    box.querySelector('#umSmartFilterReset').addEventListener('click', () => {
      selectedBrand = 'all'; selectedModel = 'all'; selectedColor = 'all';
      fillFilterOptions();
      apply();
    });

    const input = document.getElementById('q');
    if (input) input.placeholder = 'ค้นหา ยี่ห้อ / รุ่น / ปี / สี / ราคา…';
    return box;
  }

  function filterSummaryText() {
    const brandText = selectedBrand === 'all' ? 'ทุกยี่ห้อ' : (document.getElementById('umBrandFilter')?.selectedOptions?.[0]?.textContent || 'ทุกยี่ห้อ');
    const modelText = selectedModel === 'all' ? 'ทุกรุ่น' : (document.getElementById('umModelFilter')?.selectedOptions?.[0]?.textContent || 'ทุกรุ่น');
    const colorText = selectedColor === 'all' ? 'ทุกสี' : (document.getElementById('colorFilter')?.selectedOptions?.[0]?.textContent || 'ทุกสี');
    return brandText + ' • ' + modelText + ' • ' + colorText;
  }

  function updateFilterSummary() {
    const box = document.getElementById('umSmartVehicleFilter');
    if (!box) return;
    const desc = box.querySelector('#umSmartFilterDesc');
    const toggle = box.querySelector('#umSmartFilterToggle');
    if (desc) {
      desc.textContent = box.classList.contains('is-collapsed')
        ? filterSummaryText()
        : 'เลือก ยี่ห้อ / รุ่น / สี เพื่อค้นหารถได้เร็วขึ้น';
    }
    if (toggle) toggle.setAttribute('aria-expanded', box.classList.contains('is-collapsed') ? 'false' : 'true');
  }

  function initialCollapsedState() {
    try {
      const saved = localStorage.getItem('um_showroom_filter_collapsed');
      if (saved === '1') return true;
      if (saved === '0') return false;
    } catch (_) {}
    return window.matchMedia && window.matchMedia('(max-width: 768px)').matches;
  }

  function setFilterCollapsed(collapsed, persist) {
    const box = document.getElementById('umSmartVehicleFilter');
    if (!box) return;
    box.classList.toggle('is-collapsed', !!collapsed);
    if (persist) {
      try { localStorage.setItem('um_showroom_filter_collapsed', collapsed ? '1' : '0'); } catch (_) {}
    }
    updateFilterSummary();
  }

  function fillSelect(select, allLabel, total, options, selected) {
    if (!select) return;
    select.innerHTML = '<option value="all">' + escapeText(allLabel) + ' (' + total + ')</option>' + options.map((item) =>
      '<option value="' + escapeText(item.key) + '">' + escapeText(item.label) + ' (' + item.count + ')</option>'
    ).join('');
    select.value = options.some((item) => item.key === selected) ? selected : 'all';
  }

  function fillFilterOptions() {
    const box = ensureFilterUi();
    if (!box || typeof ALL === 'undefined' || !Array.isArray(ALL)) return;

    const source = ALL;
    const brands = groupedOptions(source, brandName);
    if (selectedBrand !== 'all' && !brands.some((item) => item.key === selectedBrand)) {
      selectedBrand = 'all'; selectedModel = 'all'; selectedColor = 'all';
    }

    const brandCars = filterByBrand(source);
    const models = groupedOptions(brandCars, modelName);
    if (selectedModel !== 'all' && !models.some((item) => item.key === selectedModel)) {
      selectedModel = 'all'; selectedColor = 'all';
    }

    const modelCars = filterByModel(brandCars);
    const colorMap = new Map();
    modelCars.forEach((car) => {
      const label = colorGroup(car);
      if (!label) return;
      colorMap.set(label, (colorMap.get(label) || 0) + 1);
    });
    const colorKeys = COLOR_ORDER.filter((key) => colorMap.has(key));
    const extraKeys = [...colorMap.keys()].filter((key) => !COLOR_ORDER.includes(key)).sort((a, b) => a.localeCompare(b, 'th'));
    const colors = colorKeys.concat(extraKeys).map((label) => ({ key: label, label, count: colorMap.get(label) || 0 }));
    if (selectedColor !== 'all' && !colorMap.has(selectedColor)) selectedColor = 'all';

    fillSelect(document.getElementById('umBrandFilter'), 'ทุกยี่ห้อ', source.length, brands, selectedBrand);
    fillSelect(document.getElementById('umModelFilter'), 'ทุกรุ่น', brandCars.length, models, selectedModel);
    fillSelect(document.getElementById('colorFilter'), 'ทุกสี', modelCars.length, colors, selectedColor);

    const modelSelect = document.getElementById('umModelFilter');
    const colorSelect = document.getElementById('colorFilter');
    if (modelSelect) modelSelect.disabled = models.length === 0;
    if (colorSelect) colorSelect.disabled = colors.length === 0;
    box.classList.toggle('has-selection', selectedBrand !== 'all' || selectedModel !== 'all' || selectedColor !== 'all');
    updateFilterSummary();
  }

  function dotStyle(group) {
    return 'background:' + (COLOR_DOTS[group] || COLOR_DOTS['อื่น ๆ']);
  }

  function annotateCards() {
    try {
      const start = Math.max(0, ((Number(page) || 1) - 1) * (Number(PAGE_SIZE) || 40));
      const rows = VIEW.slice(start, start + (Number(PAGE_SIZE) || 40));
      document.querySelectorAll('#grid .card').forEach((card, index) => {
        const car = rows[index];
        const name = colorName(car);
        if (!name) return;
        const meta = card.querySelector('.card-meta');
        if (!meta || meta.querySelector('[data-um-color]')) return;
        const tag = document.createElement('span');
        tag.className = 'showroom-color-tag';
        tag.dataset.umColor = '1';
        tag.innerHTML = '<i class="showroom-color-dot" style="' + dotStyle(colorGroup(car)) + '"></i>สี ' + escapeText(name);
        meta.appendChild(tag);
      });
    } catch (error) {
      console.warn('[showroom-smart-filter] annotate cards:', error);
    }
  }

  function annotateDetail() {
    try {
      const name = colorName(cur);
      const specs = document.querySelector('#sheet .specs, .sheet .specs');
      if (!name || !specs || specs.querySelector('[data-um-color-spec]')) return;
      const spec = document.createElement('div');
      spec.className = 'spec showroom-color-spec';
      spec.dataset.umColorSpec = '1';
      spec.innerHTML = '<span>สีรถ</span><b><i class="showroom-color-dot" style="' + dotStyle(colorGroup(cur)) + '"></i>' + escapeText(name) + '</b>';
      specs.appendChild(spec);
    } catch (error) {
      console.warn('[showroom-smart-filter] annotate detail:', error);
    }
  }

  function carMatchesFilters(car) {
    if (selectedBrand !== 'all' && keyOf(brandName(car)) !== selectedBrand) return false;
    if (selectedModel !== 'all' && keyOf(modelName(car)) !== selectedModel) return false;
    if (selectedColor !== 'all' && colorGroup(car) !== selectedColor) return false;
    return true;
  }

  function install() {
    if (installed) return true;
    try {
      if (typeof apply !== 'function' || typeof renderGrid !== 'function' || typeof renderSheet !== 'function') return false;
      if (typeof ALL === 'undefined' || typeof VIEW === 'undefined') return false;

      const baseApply = apply;
      const baseRenderGrid = renderGrid;
      const baseRenderSheet = renderSheet;

      renderGrid = function () {
        const result = baseRenderGrid.apply(this, arguments);
        annotateCards();
        return result;
      };

      renderSheet = function () {
        const result = baseRenderSheet.apply(this, arguments);
        annotateDetail();
        return result;
      };

      apply = function () {
        const sourceCars = ALL;
        const sourceQuery = query;
        const normalizedQuery = String(sourceQuery || '').trim().toLowerCase();
        try {
          ALL = sourceCars.filter((car) => {
            if (!carMatchesFilters(car)) return false;
            if (normalizedQuery && !searchBlob(car).includes(normalizedQuery)) return false;
            return true;
          });
          query = '';
          return baseApply.apply(this, arguments);
        } finally {
          ALL = sourceCars;
          query = sourceQuery;
          fillFilterOptions();
        }
      };

      document.addEventListener('click', (event) => {
        if (!event.target.closest('#resetAll')) return;
        selectedBrand = 'all'; selectedModel = 'all'; selectedColor = 'all';
        fillFilterOptions();
      }, true);

      injectStyles();
      ensureFilterUi();
      fillFilterOptions();
      installed = true;

      if (Array.isArray(ALL) && ALL.length) apply();
      return true;
    } catch (error) {
      console.error('[showroom-smart-filter] install failed:', error);
      return false;
    }
  }

  let attempts = 0;
  const timer = setInterval(() => {
    attempts += 1;
    if (install() || attempts >= 100) clearInterval(timer);
  }, 200);
})();
