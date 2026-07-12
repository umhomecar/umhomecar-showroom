/* UMHOME Showroom Color Add-on v1
   วางไฟล์นี้ไว้ข้าง index.html และเพิ่มก่อน </body>:
   <script src="showroom-color-addon.js?v=1"></script>
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

  let selectedColor = 'all';
  let installed = false;

  function inferColorGroup(value) {
    const compact = String(value || '').trim().replace(/\s+/g, '').toLowerCase();
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

  function colorGroup(car) {
    return String(car && car.color_group || '').trim() || inferColorGroup(car && car.color_name);
  }

  function colorName(car) {
    return String(car && (car.color_name || car.color_group) || '').trim();
  }

  function searchBlob(car) {
    return [
      car && car.brand, car && car.model, car && car.sub_model, car && car.year,
      car && car.price, car && car.engine, car && car.gear,
      car && car.color_group, car && car.color_name,
      car && car.license_plate
    ].filter(Boolean).join(' ').toLowerCase();
  }

  function injectStyles() {
    if (document.getElementById('um-color-addon-style')) return;
    const style = document.createElement('style');
    style.id = 'um-color-addon-style';
    style.textContent = `
      .showroom-color-tag{display:inline-flex!important;align-items:center;gap:5px}
      .showroom-color-dot{display:inline-block;width:11px;height:11px;border-radius:50%;border:1px solid rgba(30,25,20,.2);box-shadow:inset 0 0 0 1px rgba(255,255,255,.35);flex:none}
      .showroom-color-select{min-width:112px}
      .showroom-color-spec .showroom-color-dot{width:13px;height:13px;margin-right:5px;vertical-align:-1px}
      @media(max-width:680px){.showroom-color-select{flex:1;min-width:105px}}
    `;
    document.head.appendChild(style);
  }

  function colorCounts() {
    const counts = {};
    try {
      ALL.forEach((car) => {
        const group = colorGroup(car);
        if (group) counts[group] = (counts[group] || 0) + 1;
      });
    } catch (_) {}
    return counts;
  }

  function fillColorOptions(select) {
    const counts = colorCounts();
    const known = COLOR_ORDER.filter((key) => counts[key] || key === selectedColor);
    const extras = Object.keys(counts).filter((key) => !COLOR_ORDER.includes(key)).sort((a,b) => a.localeCompare(b, 'th'));
    select.innerHTML = '<option value="all">ทุกสี</option>' + known.concat(extras).map((key) =>
      '<option value="' + escapeOption(key) + '">' + escapeText(key) + ' (' + (counts[key] || 0) + ')</option>'
    ).join('');
    select.value = known.concat(extras).includes(selectedColor) ? selectedColor : 'all';
    if (select.value === 'all') selectedColor = 'all';
  }

  function escapeText(value) {
    return String(value || '').replace(/[&<>"']/g, (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  }

  function escapeOption(value) {
    return escapeText(value);
  }

  function injectFilter() {
    let select = document.getElementById('colorFilter');
    if (!select) {
      const price = document.getElementById('priceRange');
      const row = price && price.closest('.row');
      if (!row) return false;
      select = document.createElement('select');
      select.className = 'sort showroom-color-select';
      select.id = 'colorFilter';
      select.setAttribute('aria-label', 'กรองตามสีรถ');
      price.insertAdjacentElement('afterend', select);
      select.addEventListener('change', () => {
        selectedColor = select.value || 'all';
        apply();
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    }
    fillColorOptions(select);
    const input = document.getElementById('q');
    if (input) input.placeholder = 'ค้นหา ยี่ห้อ / รุ่น / ปี / สี / ราคา…';
    return true;
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
      console.warn('[showroom-color] annotate cards:', error);
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
      console.warn('[showroom-color] annotate detail:', error);
    }
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
            if (selectedColor !== 'all' && colorGroup(car) !== selectedColor) return false;
            if (normalizedQuery && !searchBlob(car).includes(normalizedQuery)) return false;
            return true;
          });
          query = '';
          return baseApply.apply(this, arguments);
        } finally {
          ALL = sourceCars;
          query = sourceQuery;
          const select = document.getElementById('colorFilter');
          if (select) fillColorOptions(select);
        }
      };

      document.addEventListener('click', (event) => {
        if (!event.target.closest('#resetAll')) return;
        selectedColor = 'all';
        const select = document.getElementById('colorFilter');
        if (select) select.value = 'all';
      }, true);

      injectStyles();
      injectFilter();
      installed = true;

      // กรณีข้อมูลโหลดเสร็จก่อนติดตั้ง ให้แสดงผลใหม่หนึ่งรอบ
      if (Array.isArray(ALL) && ALL.length) apply();
      return true;
    } catch (error) {
      console.error('[showroom-color] install failed:', error);
      return false;
    }
  }

  let attempts = 0;
  const timer = setInterval(() => {
    attempts += 1;
    if (install() || attempts >= 100) clearInterval(timer);
  }, 200);
})();
