import { HARDWARE } from '@px240c/runtime';
import './style.css';

const studio = document.querySelector<HTMLElement>('#studio');
if (studio === null) {
  throw new Error('PX-240C studio root is missing');
}

const visualKilobytes = String(HARDWARE.visualCapacityBytes / 1024);
const audioVoices = String(HARDWARE.audioVoices);

studio.innerHTML = `
  <section class="display" aria-label="PX-240C monitor">
    <p>PX-240C COLOR DEVELOPMENT UNIT</p>
    <p>SYSTEM ROM 1.0&nbsp; (C) 1999</p>
    <p>${visualKilobytes}K VISUAL STORE / ${audioVoices}V SOUND</p>
    <p>PXCL/1 READY</p>
    <p class="prompt" aria-label="command prompt">&gt;<span aria-hidden="true">_</span></p>
  </section>
`;
