/* ═══════════════════════════════════════════════
   PBR Texture Forge — Engine
   Client-side PBR map generation from color textures
   Saves via POST to local Node server
   ═══════════════════════════════════════════════ */

(() => {
  'use strict';

  let sourceImage = null, sourceData = null, grayData = null;
  let W = 0, H = 0, sourceBaseName = '';

  const $ = id => document.getElementById(id);
  const uploadZone = $('upload-zone'), fileInput = $('file-input');
  const sourceSection = $('source-section'), mapsSection = $('maps-section');
  const sourceCanvas = $('source-canvas'), normalCanvas = $('normal-canvas');
  const roughCanvas = $('roughness-canvas'), metalCanvas = $('metalness-canvas');
  const emissiveCanvas = $('emissive-canvas'), previewCanvas = $('preview-canvas');
  const imgDimensions = $('img-dimensions'), fileNameDisplay = $('file-name');

  function stripExt(n) { const d=n.lastIndexOf('.'); return d>0?n.substring(0,d):n; }
  function srcAlpha(i) { return sourceData.data[i*4+3]; }

  // ── Check if running on localhost (server mode) ──
  const isServerMode = location.protocol !== 'file:';
  window.addEventListener('DOMContentLoaded', () => {
    const st = $('save-status');
    if (!isServerMode && st) {
      st.innerHTML = '⚠ For folder saving, close this and run <strong>Start.bat</strong> instead.';
      st.style.color = '#f0913a';
    }
  });

  // ── File Upload ────────────────────────────
  uploadZone.addEventListener('click', () => fileInput.click());
  $('btn-change').addEventListener('click', e => { e.stopPropagation(); fileInput.click(); });
  uploadZone.addEventListener('dragover', e => { e.preventDefault(); uploadZone.classList.add('drag-over'); });
  uploadZone.addEventListener('dragleave', () => uploadZone.classList.remove('drag-over'));
  uploadZone.addEventListener('drop', e => { e.preventDefault(); uploadZone.classList.remove('drag-over'); if(e.dataTransfer.files.length) handleFile(e.dataTransfer.files[0]); });
  fileInput.addEventListener('change', () => { if(fileInput.files.length) handleFile(fileInput.files[0]); });

  function handleFile(file) {
    if (!file.type.startsWith('image/')) return;
    sourceBaseName = stripExt(file.name);
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      sourceImage = img; W = img.naturalWidth; H = img.naturalHeight;
      imgDimensions.textContent = `${W} × ${H}`;
      if (fileNameDisplay) fileNameDisplay.textContent = file.name;
      sourceCanvas.width = W; sourceCanvas.height = H;
      sourceCanvas.getContext('2d').drawImage(img, 0, 0);
      sourceData = sourceCanvas.getContext('2d').getImageData(0, 0, W, H);
      buildGrayscale();
      uploadZone.classList.add('hidden');
      sourceSection.classList.remove('hidden');
      mapsSection.classList.remove('hidden');
      const sl = $('save-label');
      if (sl) sl.textContent = `Will save as: ${sourceBaseName}Normal.png, ${sourceBaseName}Roughness.png, etc.`;
      generateAll();
      URL.revokeObjectURL(url);
    };
    img.src = url;
  }

  function buildGrayscale() {
    const d = sourceData.data; grayData = new Float32Array(W*H);
    for (let i=0;i<W*H;i++) grayData[i] = 0.299*d[i*4]+0.587*d[i*4+1]+0.114*d[i*4+2];
  }

  function boxBlur(src,w,h,r) {
    if(r<1) return new Float32Array(src);
    let inp=new Float32Array(src), out=new Float32Array(w*h);
    for(let y=0;y<h;y++) for(let x=0;x<w;x++){let s=0,c=0;for(let dx=-r;dx<=r;dx++){s+=inp[y*w+Math.min(Math.max(x+dx,0),w-1)];c++;}out[y*w+x]=s/c;}
    inp=out;out=new Float32Array(w*h);
    for(let y=0;y<h;y++) for(let x=0;x<w;x++){let s=0,c=0;for(let dy=-r;dy<=r;dy++){s+=inp[Math.min(Math.max(y+dy,0),h-1)*w+x];c++;}out[y*w+x]=s/c;}
    return out;
  }
  function sampleGray(d,x,y){return d[Math.max(0,Math.min(y,H-1))*W+Math.max(0,Math.min(x,W-1))];}

  // ── Map Generators ─────────────────────────
  function generateNormalMap() {
    const str=parseFloat($('normal-strength').value),blur=parseInt($('normal-blur').value),inv=$('normal-invert-y').checked;
    const hm=boxBlur(grayData,W,H,blur);
    normalCanvas.width=W;normalCanvas.height=H;
    const ctx=normalCanvas.getContext('2d'),id=ctx.createImageData(W,H),o=id.data;
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const tl=sampleGray(hm,x-1,y-1)/255,t=sampleGray(hm,x,y-1)/255,tr=sampleGray(hm,x+1,y-1)/255;
      const l=sampleGray(hm,x-1,y)/255,r=sampleGray(hm,x+1,y)/255;
      const bl=sampleGray(hm,x-1,y+1)/255,b=sampleGray(hm,x,y+1)/255,br=sampleGray(hm,x+1,y+1)/255;
      let nx=-((tr+2*r+br)-(tl+2*l+bl))*str,ny=(inv?1:-1)*((bl+2*b+br)-(tl+2*t+tr))*str,nz=1;
      const len=Math.sqrt(nx*nx+ny*ny+nz*nz);nx/=len;ny/=len;nz/=len;
      const i=y*W+x,idx=i*4;
      o[idx]=Math.round((nx*.5+.5)*255);o[idx+1]=Math.round((ny*.5+.5)*255);o[idx+2]=Math.round((nz*.5+.5)*255);o[idx+3]=srcAlpha(i);
    }
    ctx.putImageData(id,0,0);
  }

  function generateRoughnessMap() {
    const con=parseFloat($('rough-contrast').value),bri=parseInt($('rough-brightness').value),blur=parseInt($('rough-blur').value),inv=$('rough-invert').checked;
    let wk=boxBlur(grayData,W,H,blur);
    roughCanvas.width=W;roughCanvas.height=H;
    const ctx=roughCanvas.getContext('2d'),id=ctx.createImageData(W,H),o=id.data;
    for(let i=0;i<W*H;i++){let v=((wk[i]/255-.5)*con+.5)*255+bri;if(inv)v=255-v;v=Math.max(0,Math.min(255,Math.round(v)));const idx=i*4;o[idx]=o[idx+1]=o[idx+2]=v;o[idx+3]=srcAlpha(i);}
    ctx.putImageData(id,0,0);
  }

  function generateMetalnessMap() {
    const thr=parseInt($('metal-threshold').value),sm=parseInt($('metal-smooth').value),flat=$('metal-flat-black').checked;
    metalCanvas.width=W;metalCanvas.height=H;
    const ctx=metalCanvas.getContext('2d'),id=ctx.createImageData(W,H),o=id.data;
    if(flat){for(let i=0;i<W*H;i++){const idx=i*4;o[idx]=o[idx+1]=o[idx+2]=0;o[idx+3]=srcAlpha(i);}}
    else{let wk=boxBlur(grayData,W,H,sm);for(let i=0;i<W*H;i++){let v=1/(1+Math.exp(-(wk[i]-thr)/20));v=Math.max(0,Math.min(255,Math.round(v*255)));const idx=i*4;o[idx]=o[idx+1]=o[idx+2]=v;o[idx+3]=srcAlpha(i);}}
    ctx.putImageData(id,0,0);
  }

  function generateEmissiveMap() {
    const thr=parseInt($('emissive-threshold').value),inten=parseFloat($('emissive-intensity').value),kc=$('emissive-color').checked;
    const d=sourceData.data;emissiveCanvas.width=W;emissiveCanvas.height=H;
    const ctx=emissiveCanvas.getContext('2d'),id=ctx.createImageData(W,H),o=id.data;
    for(let i=0;i<W*H;i++){
      const r=d[i*4],g=d[i*4+1],b=d[i*4+2],lum=.299*r+.587*g+.114*b;
      let m=lum>=thr?Math.min(1,(lum-thr)/(255-thr+1))*inten:0;m=Math.min(1,Math.max(0,m));
      const idx=i*4;
      if(kc){o[idx]=Math.min(255,Math.round(r*m));o[idx+1]=Math.min(255,Math.round(g*m));o[idx+2]=Math.min(255,Math.round(b*m));}
      else{const v=Math.min(255,Math.round(lum*m));o[idx]=o[idx+1]=o[idx+2]=v;}
      o[idx+3]=srcAlpha(i);
    }
    ctx.putImageData(id,0,0);
  }

  // ── Isometric 3D Block Preview ─────────────
  let lightAzimuth=-0.6, lightElevation=0.8;
  const AY=Math.PI/4,AX=Math.atan(1/Math.sqrt(2));
  const cosAY=Math.cos(AY),sinAY=Math.sin(AY),cosAX=Math.cos(AX),sinAX=Math.sin(AX);
  function project3D(x,y,z){const rx=x*cosAY+z*sinAY,ry=y,rz=-x*sinAY+z*cosAY;return[rx,-(ry*cosAX-rz*sinAX)];}
  const FACE_TBN={top:{T:[1,0,0],B:[0,0,1],N:[0,1,0]},left:{T:[0,0,1],B:[0,-1,0],N:[-1,0,0]},right:{T:[1,0,0],B:[0,-1,0],N:[0,0,1]}};
  function sampleCanvasToData(src,res){const c=document.createElement('canvas');c.width=res;c.height=res;c.getContext('2d').drawImage(src,0,0,res,res);return c.getContext('2d').getImageData(0,0,res,res).data;}

  function generateLightingPreview() {
    const SIZE=480,CUBE=SIZE*0.30;
    previewCanvas.width=SIZE;previewCanvas.height=SIZE;
    const ctx=previewCanvas.getContext('2d');ctx.fillStyle='#0a0b0e';ctx.fillRect(0,0,SIZE,SIZE);
    const s=CUBE,raw=[project3D(-s,-s,-s),project3D(s,-s,-s),project3D(s,-s,s),project3D(-s,-s,s),project3D(-s,s,-s),project3D(s,s,-s),project3D(s,s,s),project3D(-s,s,s)];
    const cx=SIZE/2,cy=SIZE/2,verts=raw.map(v=>[v[0]+cx,v[1]+cy]);
    const kx=Math.cos(lightElevation)*Math.sin(lightAzimuth),ky=Math.sin(lightElevation),kz=Math.cos(lightElevation)*Math.cos(lightAzimuth);
    const kLen=Math.sqrt(kx*kx+ky*ky+kz*kz)||1,KEY=[kx/kLen,ky/kLen,kz/kLen];
    const FILL=[-KEY[0]*0.5+0.1,0.3,-KEY[2]*0.5+0.2],fLen=Math.sqrt(FILL[0]**2+FILL[1]**2+FILL[2]**2)||1;FILL[0]/=fLen;FILL[1]/=fLen;FILL[2]/=fLen;
    const RIM=[-KEY[0],-0.2,-KEY[2]],rLen=Math.sqrt(RIM[0]**2+RIM[1]**2+RIM[2]**2)||1;RIM[0]/=rLen;RIM[1]/=rLen;RIM[2]/=rLen;
    const V=[0,sinAX,cosAX],TEX_RES=256;
    const colorTex=sampleCanvasToData(sourceCanvas,TEX_RES),normalTex=sampleCanvasToData(normalCanvas,TEX_RES),roughTex=sampleCanvasToData(roughCanvas,TEX_RES);
    function renderFace(p0,p1,p2,p3,tbn){
      const tile=document.createElement('canvas');tile.width=TEX_RES;tile.height=TEX_RES;
      const tctx=tile.getContext('2d'),img=tctx.createImageData(TEX_RES,TEX_RES),out=img.data;const{T,B,N}=tbn;
      for(let py=0;py<TEX_RES;py++)for(let px=0;px<TEX_RES;px++){
        const idx=(py*TEX_RES+px)*4,cr=colorTex[idx],cg=colorTex[idx+1],cb=colorTex[idx+2];
        const tnx=(normalTex[idx]/255)*2-1,tny=(normalTex[idx+1]/255)*2-1,tnz=(normalTex[idx+2]/255)*2-1;
        let wnx=T[0]*tnx+B[0]*tny+N[0]*tnz,wny=T[1]*tnx+B[1]*tny+N[1]*tnz,wnz=T[2]*tnx+B[2]*tny+N[2]*tnz;
        const nlen=Math.sqrt(wnx*wnx+wny*wny+wnz*wnz)||1;wnx/=nlen;wny/=nlen;wnz/=nlen;
        const roughness=roughTex[idx]/255,smoothness=1-roughness;
        const keyDiff=Math.max(0,wnx*KEY[0]+wny*KEY[1]+wnz*KEY[2]);
        let hx=KEY[0]+V[0],hy=KEY[1]+V[1],hz=KEY[2]+V[2],hl=Math.sqrt(hx*hx+hy*hy+hz*hz)||1;hx/=hl;hy/=hl;hz/=hl;
        const keyNdotH=Math.max(0,wnx*hx+wny*hy+wnz*hz),keyShininess=4+smoothness*smoothness*512,keySpec=Math.pow(keyNdotH,keyShininess)*smoothness*1.2;
        const fillDiff=Math.max(0,wnx*FILL[0]+wny*FILL[1]+wnz*FILL[2])*0.35;
        const NdotV=Math.max(0,wnx*V[0]+wny*V[1]+wnz*V[2]),fresnel=Math.pow(1-NdotV,3)*smoothness*0.6;
        const rimDiff=Math.max(0,wnx*RIM[0]+wny*RIM[1]+wnz*RIM[2]),rimContrib=rimDiff*fresnel;
        const ambient=0.04,diffuse=keyDiff*0.85+fillDiff,specular=keySpec,rim=rimContrib;
        let lr=ambient+diffuse+specular+rim,lg=ambient+diffuse+specular*0.95+rim,lb=ambient+diffuse*1.05+fillDiff*0.15+specular*0.9+rim;
        out[idx]=Math.min(255,Math.max(0,Math.round(cr*lr)));out[idx+1]=Math.min(255,Math.max(0,Math.round(cg*lg)));out[idx+2]=Math.min(255,Math.max(0,Math.round(cb*lb)));out[idx+3]=255;
      }
      tctx.putImageData(img,0,0);
      ctx.save();ctx.beginPath();ctx.moveTo(p0[0],p0[1]);ctx.lineTo(p1[0],p1[1]);ctx.lineTo(p3[0],p3[1]);ctx.lineTo(p2[0],p2[1]);ctx.closePath();ctx.clip();
      ctx.setTransform((p1[0]-p0[0])/TEX_RES,(p1[1]-p0[1])/TEX_RES,(p2[0]-p0[0])/TEX_RES,(p2[1]-p0[1])/TEX_RES,p0[0],p0[1]);
      ctx.drawImage(tile,0,0);ctx.restore();
    }
    renderFace(verts[4],verts[5],verts[7],verts[6],FACE_TBN.top);
    renderFace(verts[4],verts[7],verts[0],verts[3],FACE_TBN.left);
    renderFace(verts[7],verts[6],verts[3],verts[2],FACE_TBN.right);
    ctx.strokeStyle='rgba(255,255,255,0.07)';ctx.lineWidth=1;
    function edge(a,b){ctx.beginPath();ctx.moveTo(verts[a][0],verts[a][1]);ctx.lineTo(verts[b][0],verts[b][1]);ctx.stroke();}
    edge(4,5);edge(5,6);edge(6,7);edge(7,4);edge(4,0);edge(0,3);edge(3,7);edge(3,2);edge(2,6);edge(6,2);edge(4,0);
    const bottomY=Math.max(verts[0][1],verts[1][1],verts[2][1],verts[3][1]);
    const grd=ctx.createRadialGradient(cx,bottomY+8,0,cx,bottomY+8,CUBE*1.2);grd.addColorStop(0,'rgba(0,0,0,0.3)');grd.addColorStop(1,'rgba(0,0,0,0)');ctx.fillStyle=grd;ctx.fillRect(cx-CUBE*1.5,bottomY,CUBE*3,40);
    const lpx=cx+KEY[0]*CUBE*1.8,lpy=cy-KEY[1]*CUBE*1.8;ctx.beginPath();ctx.arc(lpx,lpy,5,0,Math.PI*2);ctx.fillStyle='rgba(255,230,120,0.9)';ctx.fill();ctx.beginPath();ctx.arc(lpx,lpy,9,0,Math.PI*2);ctx.strokeStyle='rgba(255,230,120,0.2)';ctx.lineWidth=2;ctx.stroke();
  }

  previewCanvas.addEventListener('mousemove',e=>{const r=previewCanvas.getBoundingClientRect();lightAzimuth=((e.clientX-r.left)/r.width-0.5)*Math.PI*1.5;lightElevation=(1-(e.clientY-r.top)/r.height)*Math.PI*0.5+0.1;if(sourceImage)generateLightingPreview();});
  previewCanvas.addEventListener('mouseleave',()=>{lightAzimuth=-0.6;lightElevation=0.8;if(sourceImage)generateLightingPreview();});

  function generateAll(){if(!sourceImage)return;generateNormalMap();generateRoughnessMap();generateMetalnessMap();generateEmissiveMap();generateLightingPreview();}
  $('btn-generate').addEventListener('click',generateAll);

  document.querySelectorAll('.slider-val').forEach(span=>{const input=$(span.dataset.for);if(input)input.addEventListener('input',()=>{span.textContent=input.value;});});
  let regenTimer=null;
  function debouncedRegen(fn){clearTimeout(regenTimer);regenTimer=setTimeout(()=>{fn();generateLightingPreview();},100);}
  ['normal-strength','normal-blur'].forEach(id=>$(id).addEventListener('input',()=>debouncedRegen(generateNormalMap)));
  $('normal-invert-y').addEventListener('change',()=>debouncedRegen(generateNormalMap));
  ['rough-contrast','rough-brightness','rough-blur'].forEach(id=>$(id).addEventListener('input',()=>debouncedRegen(generateRoughnessMap)));
  $('rough-invert').addEventListener('change',()=>debouncedRegen(generateRoughnessMap));
  ['metal-threshold','metal-smooth'].forEach(id=>$(id).addEventListener('input',()=>debouncedRegen(generateMetalnessMap)));
  $('metal-flat-black').addEventListener('change',()=>debouncedRegen(generateMetalnessMap));
  ['emissive-threshold','emissive-intensity'].forEach(id=>$(id).addEventListener('input',()=>debouncedRegen(generateEmissiveMap)));
  $('emissive-color').addEventListener('change',()=>debouncedRegen(generateEmissiveMap));

  // ── Download (browser downloads) ───────────
  function downloadCanvas(c,fn){const a=document.createElement('a');a.download=fn+'.png';a.href=c.toDataURL('image/png');a.click();}
  document.querySelectorAll('.btn-download').forEach(btn=>{btn.addEventListener('click',()=>{const c=$(btn.dataset.canvas),s=btn.dataset.name;if(c)downloadCanvas(c,(sourceBaseName||'Texture')+s);});});
  function getMapList(){return[{canvas:normalCanvas,suffix:'Normal'},{canvas:roughCanvas,suffix:'Roughness'},{canvas:metalCanvas,suffix:'Metalness'},{canvas:emissiveCanvas,suffix:'Emissive'}];}
  $('btn-download-all').addEventListener('click',()=>{const b=sourceBaseName||'Texture';getMapList().forEach((m,i)=>setTimeout(()=>downloadCanvas(m.canvas,b+m.suffix),i*300));});

  // ══════════════════════════════════════════════
  //  SAVE TO FOLDER via Node server POST
  //  Works on ANY browser — no special APIs needed
  // ══════════════════════════════════════════════

  async function saveAllToFolder() {
    if (!sourceImage) return;
    const base = sourceBaseName || 'Texture';
    const st = $('save-status');
    const dirInput = $('save-dir');
    const directory = dirInput ? dirInput.value.trim() : '';

    if (!isServerMode) {
      if (st) {
        st.innerHTML = '⚠ Run <strong>Start.bat</strong> to enable folder saving.';
        st.style.color = '#f0913a';
      }
      return;
    }

    const maps = getMapList();
    let saved = 0;

    try {
      for (const m of maps) {
        const fn = `${base}${m.suffix}.png`;
        if (st) { st.textContent = `Saving ${fn}…`; st.style.color = '#3ddc84'; }

        const dataUrl = m.canvas.toDataURL('image/png');
        const resp = await fetch('/save', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            filename: fn,
            dataUrl: dataUrl,
            directory: directory || undefined
          })
        });

        const result = await resp.json();
        if (!result.ok) throw new Error(result.error);
        saved++;
      }

      if (st) {
        st.textContent = `✓ Saved ${saved} maps` + (directory ? ` to ${directory}` : ' next to server');
        st.style.color = '#3ddc84';
        setTimeout(() => { st.textContent = ''; }, 6000);
      }
    } catch (err) {
      console.error('Save failed:', err);
      if (st) {
        st.textContent = `Error: ${err.message}`;
        st.style.color = '#f04a5e';
        setTimeout(() => { st.textContent = ''; }, 6000);
      }
    }
  }

  $('btn-save-all').addEventListener('click', saveAllToFolder);
})();
