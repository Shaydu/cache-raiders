/**
 * Modal Manager - Handles modal display and object details
 */
const ModalManager = {
    /**
     * Open object modal with details
     */
    async openObjectModal(objectId) {
        const modal = document.getElementById('objectModal');
        const modalBody = document.getElementById('modalBody');
        const modalTitle = document.getElementById('modalTitle');

        if (!modal || !modalBody || !modalTitle) return;

        // Show modal with loading state
        modal.classList.add('active');
        modalBody.innerHTML = '<div class="loading">Loading object details...</div>';

        try {
            const obj = await ApiService.objects.getById(objectId);

            // Format dates
            const createdDate = new Date(obj.created_at).toLocaleString();
            const foundDate = obj.found_at ? new Date(obj.found_at).toLocaleString() : null;

            // Build modal content
            // Use the stored name from the database (what admin typed when creating)
            modalTitle.textContent = obj.name || obj.type;
            modalBody.innerHTML = `
                <div class="modal-field">
                    <div class="modal-field-label">Name</div>
                    <div class="modal-field-value">${obj.name || obj.type}</div>
                </div>
                
                <div class="modal-field">
                    <div class="modal-field-label">Type</div>
                    <div class="modal-field-value">${obj.type}</div>
                </div>
                
                <div class="modal-field">
                    <div class="modal-field-label">Status</div>
                    <div class="modal-field-value ${obj.collected ? 'status-collected' : 'status-available'}">
                        ${obj.collected ? '✓ Collected' : '● Available'}
                    </div>
                </div>
                
                <div class="modal-field">
                    <div class="modal-field-label">Location</div>
                    <div class="modal-field-value">
                        ${obj.latitude.toFixed(6)}, ${obj.longitude.toFixed(6)}
                    </div>
                </div>
                
                <div class="modal-field">
                    <div class="modal-field-label">Radius</div>
                    <div class="modal-field-value">${obj.radius} meters</div>
                </div>
                
                ${obj.grounding_height !== null ? `
                <div class="modal-field">
                    <div class="modal-field-label">Grounding Height</div>
                    <div class="modal-field-value">${obj.grounding_height.toFixed(4)} meters</div>
                </div>
                ` : ''}
                
                <div class="modal-field">
                    <div class="modal-field-label">Created At</div>
                    <div class="modal-field-value">${createdDate}</div>
                </div>
                
                ${obj.created_by ? `
                <div class="modal-field">
                    <div class="modal-field-label">Created By</div>
                    <div class="modal-field-value">${obj.created_by}</div>
                </div>
                ` : ''}
                
                ${obj.collected ? `
                <div class="modal-field">
                    <div class="modal-field-label">Found By</div>
                    <div class="modal-field-value">${obj.found_by || 'Unknown'}</div>
                </div>
                
                <div class="modal-field">
                    <div class="modal-field-label">Found At</div>
                    <div class="modal-field-value">${foundDate}</div>
                </div>
                ` : ''}
                
                <div class="modal-field">
                    <div class="modal-field-label">Object ID</div>
                    <div class="modal-field-value" style="font-size: 12px; font-family: monospace; word-break: break-all;">${obj.id}</div>
                </div>
                
                <div class="modal-actions">
                    <button class="btn-danger" onclick="ModalManager.deleteObjectFromModal('${obj.id}')">Delete Object</button>
                    <button onclick="ModalManager.closeModal()">Close</button>
                </div>
            `;
        } catch (error) {
            console.error('Error loading object details:', error);
            modalBody.innerHTML = `
                <div class="status error">
                    Error loading object details: ${error.message}
                </div>
                <div class="modal-actions">
                    <button onclick="ModalManager.closeModal()">Close</button>
                </div>
            `;
        }
    },

    /**
     * Close modal
     */
    closeModal() {
        const modal = document.getElementById('objectModal');
        if (modal) {
            modal.classList.remove('active');
        }
    },

    /**
     * Delete object from modal
     */
    async deleteObjectFromModal(objectId) {
        if (!confirm('Are you sure you want to delete this object? This action cannot be undone.')) {
            return;
        }

        try {
            await ApiService.objects.delete(objectId);
            UI.showStatus('Object deleted successfully', 'success');
            this.closeModal();
            await ObjectsManager.loadObjects();
            await StatsManager.refreshStats();
        } catch (error) {
            UI.showStatus('Error deleting object: ' + error.message, 'error');
        }
    }
};

// Make ModalManager available globally
window.ModalManager = ModalManager;

